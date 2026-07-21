import Foundation
import Security

/// Keychain persistence for the Watch's relay context.
///
/// Loading is self-healing: any value that cannot be decoded AND validated is
/// destroyed and reported as absent. A poisoned credential must never survive
/// a launch — it would otherwise wedge the app permanently, because the next
/// good context can only arrive after the app lives long enough to receive it.
enum WatchTerminalCredentialStore {
    private static let service = "air.build.pedals.watch-terminal.v2"
    private static let legacyServices = ["air.build.pedals.watch-terminal.v1"]
    private static let account = "relay-context"

    static func load() -> WatchTerminalContext? {
        purgeLegacy()

        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        guard let context = try? JSONDecoder().decode(
            WatchTerminalContext.self, from: data
        ) else {
            _ = SecItemDelete(baseQuery as CFDictionary)
            return nil
        }
        return context
    }

    static func save(_ context: WatchTerminalContext?) {
        guard let context, let data = try? JSONEncoder().encode(context) else {
            _ = SecItemDelete(baseQuery as CFDictionary)
            return
        }

        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            _ = SecItemUpdate(
                baseQuery as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
        }
    }

    private static func purgeLegacy() {
        for legacyService in legacyServices {
            _ = SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: legacyService,
                kSecAttrAccount as String: account,
            ] as CFDictionary)
        }
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
