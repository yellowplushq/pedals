import GhosttyTerminal
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    lazy var services = AppServices()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        if ProcessInfo.processInfo.environment["PEDALS_GHOSTTY_DEBUG"] != nil {
            TerminalDebugLog.isEnabled = true
            TerminalDebugLog.categories = .all
        }
        services.startSystemSurfaces()
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        AgentNotificationController.shared.handleDeviceToken(deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Simulators and denied-network cases land here; APNs registration
        // retries on the next launch/foreground via registerWhenPaired.
    }
}
