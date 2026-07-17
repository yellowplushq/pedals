import Foundation
import GhosttyTerminal
import PedalsKit

/// Composition root: one instance owns every long-lived object in the app.
@MainActor
final class AppServices {
    let preferences = TerminalPreferences()
    let pairingStore = PairingStore()
    let connection: ConnectionController
    let sessionStore: SessionStore
    /// One controller per terminal view: TerminalSurfaceCoordinator installs
    /// itself as the controller's single onWakeup/shouldProcessWakeup closure,
    /// so views sharing a controller clobber each other's render wakeups
    /// (last one wins — hidden view suspends everyone). Matches the pattern
    /// in libghostty-spm's example apps.
    private var liveControllers = NSHashTable<TerminalController>.weakObjects()

    init() {
        connection = ConnectionController(pairingStore: pairingStore)
        sessionStore = SessionStore(connection: connection)
        connection.start()
    }

    func makeTerminalController() -> TerminalController {
        let controller = TerminalController(
            configuration: TerminalConfiguration(startingFrom: .default) { builder in
                builder.withWindowPaddingX(6)
                builder.withWindowPaddingY(4)
            },
            theme: preferences.terminalTheme()
        )
        controller.setTerminalConfiguration(preferences.terminalConfiguration())
        liveControllers.add(controller)
        return controller
    }

    /// Handles a `pedals://pair?...` URL from QR scan, paste, or the URL scheme.
    @discardableResult
    func handlePairingURL(_ url: URL) -> Bool {
        guard let info = try? PairingInfo(url: url) else { return false }
        connection.pair(with: info)
        return true
    }

    static let appearanceDidChange = Notification.Name("pedals.appearanceDidChange")

    func applyTerminalAppearance() {
        for controller in liveControllers.allObjects {
            controller.setTheme(preferences.terminalTheme())
            controller.setTerminalConfiguration(preferences.terminalConfiguration())
        }
        NotificationCenter.default.post(name: Self.appearanceDidChange, object: nil)
    }
}
