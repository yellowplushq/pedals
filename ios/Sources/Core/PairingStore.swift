import Foundation
import PedalsKit
import Security

/// Persists the pairing URL in the Keychain (PROTOCOL.md §2: "iOS: Keychain").
@MainActor
final class PairingStore {
    private static let service = "app.yellowplus.pedals"
    private static let account = "pairing-url"

    func load() -> PairingInfo? {
        var query = Self.baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let urlString = String(data: data, encoding: .utf8)
        else { return nil }
        return try? PairingInfo(urlString: urlString)
    }

    func save(_ pairing: PairingInfo) {
        let data = Data(pairing.url.absoluteString.utf8)

        var attributes = Self.baseQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            SecItemUpdate(
                Self.baseQuery as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
        }
    }

    func clear() {
        SecItemDelete(Self.baseQuery as CFDictionary)
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
