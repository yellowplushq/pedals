import Foundation
import Security

/// Per-computer Live Activity content keys shared by the app and widget.
/// Only the HKDF-derived activity key crosses the keychain group; root pairing
/// secrets and relay traffic keys remain private to the app.
public enum AgentActivityKeyStore {
    public static let accessGroup = "QDJ93ZUQ9B.air.build.pedals.shared"
    static let service = "air.build.pedals.live-activity-keys"

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
            let status = SecItemUpdate(
                query as CFDictionary,
                [kSecValueData: key] as CFDictionary
            )
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
