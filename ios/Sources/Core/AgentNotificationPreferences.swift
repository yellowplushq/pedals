import Foundation
import PedalsKit

/// "Notify me when…" preferences for agent notifications, phrased by moment:
/// an agent *needs you* (waiting), *fails* (error), or *finishes* (done).
/// Device-local (UserDefaults), defaulting to everything on; the chosen set
/// rides along with the push-endpoint registration so the Worker filters
/// per device.
enum AgentNotificationPreferences {
    private static func key(_ category: AgentNotification.Category) -> String {
        "pedals.notification.when.\(category.rawValue)"
    }

    static func isEnabled(_ category: AgentNotification.Category) -> Bool {
        UserDefaults.standard.object(forKey: key(category)) as? Bool ?? true
    }

    @MainActor
    static func setEnabled(_ enabled: Bool, for category: AgentNotification.Category) {
        UserDefaults.standard.set(enabled, forKey: key(category))
        AgentNotificationController.shared.preferencesDidChange()
    }

    /// The wire form for endpoint registration; nil when everything is on
    /// (the Worker treats absent as "all").
    static func enabledCategories() -> [String]? {
        let enabled = AgentNotification.Category.allCases.filter(isEnabled)
        return enabled.count == AgentNotification.Category.allCases.count
            ? nil
            : enabled.map(\.rawValue)
    }
}
