import CryptoKit
import Foundation

/// Direction keys per PROTOCOL.md §2:
///
///     key_h2c = HKDF-SHA256(ikm=secret, salt="pedals-v1", info="host->client", 32 bytes)
///     key_c2h = HKDF-SHA256(ikm=secret, salt="pedals-v1", info="client->host", 32 bytes)
public enum KeyDerivation {
    public static let salt = Data("pedals-v1".utf8)
    public static let keyByteCount = 32

    public static func hostToClientKey(secret: Data) -> SymmetricKey {
        derive(secret: secret, info: "host->client")
    }

    public static func clientToHostKey(secret: Data) -> SymmetricKey {
        derive(secret: secret, info: "client->host")
    }

    private static func derive(secret: Data, info: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secret),
            salt: salt,
            info: Data(info.utf8),
            outputByteCount: keyByteCount
        )
    }
}
