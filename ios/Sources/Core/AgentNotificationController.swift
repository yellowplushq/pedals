import UIKit
import UserNotifications

/// Visible agent notifications (waiting/error/done pushes from the daemon,
/// AGENT_MONITORING_DESIGN.md §5): APNs registration for the `ios-notification`
/// surface, foreground presentation policy, and the tap deep-link.
///
/// Foreground policy mirrors supacode's mute-for-active-surface: a banner for
/// a terminal the user is already looking at is noise, everything else shows.
@MainActor
final class AgentNotificationController: NSObject {
    static let shared = AgentNotificationController()

    /// Deep link into a managed terminal; MainViewController installs it.
    var onOpenTerminal: ((TerminalID) -> Void)?
    /// True when the user is currently viewing the given terminal.
    var isViewingTerminal: ((TerminalID) -> Bool)?

    private var registrationStarted = false

    /// Installs the delegate. Must run at launch so a notification tap that
    /// cold-starts the app is delivered.
    func activate() {
        UNUserNotificationCenter.current().delegate = self
    }

    /// Requests authorization (first time) and registers with APNs. Called
    /// once at least one computer is bound — an unpaired install must never
    /// see a permission prompt.
    func registerWhenPaired() {
        guard !registrationStarted else { return }
        registrationStarted = true
        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            switch settings.authorizationStatus {
            case .notDetermined:
                let granted = (try? await center.requestAuthorization(
                    options: [.alert, .badge, .sound]
                )) ?? false
                guard granted else { return }
            case .denied:
                return
            default:
                break
            }
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    /// APNs device token from the AppDelegate; durable-queued like every
    /// other push endpoint so registration survives offline launches. The
    /// token is kept so a preference change can re-register without a fresh
    /// APNs round-trip.
    func handleDeviceToken(_ deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(token, forKey: Self.tokenDefaultsKey)
        registerEndpoint(token: token)
    }

    private static let tokenDefaultsKey = "pedals.notification.device-token"

    /// Re-sends the registration with the current "notify me when…"
    /// preferences. No-op until the first device token arrives.
    func preferencesDidChange() {
        guard let token = UserDefaults.standard.string(forKey: Self.tokenDefaultsKey)
        else { return }
        registerEndpoint(token: token)
    }

    private func registerEndpoint(token: String) {
        let categories = AgentNotificationPreferences.enabledCategories()
        Task {
            await PushEndpointRegistrar.registerOrQueue(
                PushEndpointRegistration(
                    surface: .iOSNotification,
                    token: token,
                    categories: categories
                )
            )
        }
    }

    /// The `pedals` dictionary of an agent-alert push, reduced to Sendable
    /// fields so the nonisolated delegate methods can carry it onto the
    /// main actor.
    fileprivate struct AlertInfo: Sendable {
        let computerID: String
        let sessionId: Int?

        init?(userInfo: [AnyHashable: Any]) {
            guard let pedals = userInfo["pedals"] as? [String: Any],
                  let computerID = pedals["computerId"] as? String
            else { return nil }
            self.computerID = computerID
            self.sessionId = pedals["sessionId"] as? Int
        }

        var terminalID: TerminalID? {
            sessionId.map { TerminalID(computerID: computerID, sid: $0) }
        }
    }

    fileprivate func presentationOptions(
        for info: AlertInfo?
    ) -> UNNotificationPresentationOptions {
        if let terminalID = info?.terminalID, isViewingTerminal?(terminalID) == true {
            return []
        }
        return [.banner, .sound, .list]
    }

    fileprivate func openFromTap(_ info: AlertInfo?) {
        guard let terminalID = info?.terminalID else { return }
        onOpenTerminal?(terminalID)
    }
}

extension AgentNotificationController: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let info = AlertInfo(userInfo: notification.request.content.userInfo)
        return await MainActor.run { self.presentationOptions(for: info) }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        let info = AlertInfo(userInfo: response.notification.request.content.userInfo)
        await MainActor.run { self.openFromTap(info) }
    }
}
