import Foundation
import Security

/// Per-computer notification keys in the shared keychain group, written by
/// the app on every bindings change and read by the Notification Service
/// Extension to decrypt sealed agent-alert content.
///
/// Only the HKDF-derived notification key crosses into the shared group —
/// never the root computer secret — so an NSE compromise exposes alert
/// content, not relay traffic or pairing state.
public enum AgentNotificationKeyStore {
    /// Runtime form of `$(AppIdentifierPrefix)air.build.pedals.shared`.
    /// The team identifier is fixed by project.yml (DEVELOPMENT_TEAM).
    public static let accessGroup = "QDJ93ZUQ9B.air.build.pedals.shared"
    static let service = "air.build.pedals.notification-keys"

    /// Replaces the stored key set: one generic-password item per computer,
    /// stale computers removed. Accessible after first unlock so alerts
    /// decrypt while the phone is locked.
    public static func setKeys(_ keys: [String: Data]) {
        let existing = allAccounts()
        for account in existing where keys[account] == nil {
            SecItemDelete([
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: account,
                kSecAttrAccessGroup: accessGroup,
            ] as CFDictionary)
        }
        for (computerID, key) in keys {
            let query: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: computerID,
                kSecAttrAccessGroup: accessGroup,
            ]
            let update: [CFString: Any] = [kSecValueData: key]
            let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            if status == errSecItemNotFound {
                var create = query
                create[kSecValueData] = key
                create[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                SecItemAdd(create as CFDictionary, nil)
            }
        }
    }

    public static func key(forComputer computerID: String) -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: computerID,
            kSecAttrAccessGroup: accessGroup,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
            return nil
        }
        return result as? Data
    }

    private static func allAccounts() -> [String] {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccessGroup: accessGroup,
            kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[CFString: Any]]
        else { return [] }
        return items.compactMap { $0[kSecAttrAccount] as? String }
    }
}
