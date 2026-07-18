import AppKit
import SwiftUI

@main
struct PedalsMenubarApp: App {
    @NSApplicationDelegateAdaptor(PedalsAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(appDelegate.updater)
        }
    }
}

@MainActor
final class PedalsAppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    let updater = UpdaterModel()

    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItemController = StatusItemController(model: model, updater: updater)
    }
}
