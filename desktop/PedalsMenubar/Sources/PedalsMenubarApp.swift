import AppKit
import SwiftUI

/// The settings window is a plain `Window` scene, not the `Settings` scene:
/// the Settings scene styles its toolbar itself (centered title, no
/// full-height sidebar), which fights the split-view look.
enum SettingsWindow {
    static let id = "pedals-settings"
}

@main
struct PedalsMenubarApp: App {
    @NSApplicationDelegateAdaptor(PedalsAppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Settings", id: SettingsWindow.id) {
            SettingsView()
                .environmentObject(appDelegate.updater)
                .environmentObject(appDelegate.permissions)
        }
        .handlesExternalEvents(matching: [])
        .windowToolbarStyle(.unified)
        .defaultSize(width: 760, height: 540)
    }
}

@MainActor
final class PedalsAppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    let updater = UpdaterModel()
    let permissions = PermissionsModel()

    private var statusItemController: StatusItemController?
    private var debugSettingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItemController = StatusItemController(
            model: model,
            updater: updater,
            permissions: permissions
        )

        // Dev affordance: land straight in the settings window so local relay
        // runs and UI screenshots don't need the status-item popover. The
        // real Window scene must render (a plain NSWindow host lays the
        // toolbar out differently), so a throwaway 1×1 bootstrap window calls
        // the same openWindow(id:) action the menu's gear button uses.
        if ProcessInfo.processInfo.environment["PEDALS_OPEN_SETTINGS"] == "1" {
            let opener = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                styleMask: [.borderless], backing: .buffered, defer: false
            )
            opener.contentViewController = NSHostingController(rootView: DebugSettingsOpener())
            opener.orderFront(nil)
            debugSettingsWindow = opener
            NSApp.activate(ignoringOtherApps: true)

            // Self-render the settings window to a PNG: capture the composited
            // window pixels (own-process windows are exempt from the
            // screen-recording gate) so sidebar vibrancy renders.
            if let path = ProcessInfo.processInfo.environment["PEDALS_SETTINGS_SNAPSHOT"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    guard let window = NSApp.windows.first(where: {
                        $0.identifier?.rawValue.contains(SettingsWindow.id) == true
                    }) else { return }
                    guard let image = CGWindowListCreateImage(
                        .null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                        [.boundsIgnoreFraming, .bestResolution]
                    ) else { return }
                    let rep = NSBitmapImageRep(cgImage: image)
                    try? rep.representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: path))
                }
            }
        }
    }
}

/// Hosted in the 1×1 bootstrap window: opens the real settings Window scene
/// through the same environment action the menu uses.
private struct DebugSettingsOpener: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .onAppear { openWindow(id: SettingsWindow.id) }
    }
}
