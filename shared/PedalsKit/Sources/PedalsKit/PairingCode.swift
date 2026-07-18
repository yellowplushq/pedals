import CryptoKit
import Foundation

/// The user-visible rendezvous handle. It authorizes one online pairing
/// session for 15 minutes, but is never used as E2EE key material.
public struct PairingCode: Codable, Equatable, Hashable, Sendable {
    public static let digitCount = 8
    public let digits: String

    public enum ValidationError: Error, Equatable {
        case invalidFormat
    }

    public init(_ value: String) throws {
        let compact = value.filter { !$0.isWhitespace && $0 != "-" }
        guard compact.count == Self.digitCount,
              compact.allSatisfy({ $0.isASCII && $0.isNumber })
        else { throw ValidationError.invalidFormat }
        digits = compact
    }

    public var formatted: String {
        "\(digits.prefix(4)) \(digits.suffix(4))"
    }
}

/// Host-only state retained while the desktop pairing page is open.
public struct HostPairingSession: Equatable, Sendable {
    public let sessionID: String
    public let code: PairingCode
    public let expiresAt: Int64
    public let privateKey: Data

    public init(sessionID: String, code: PairingCode, expiresAt: Int64, privateKey: Data) {
        self.sessionID = sessionID
        self.code = code
        self.expiresAt = expiresAt
        self.privateKey = privateKey
    }
}

public enum HostPairingSessionStatus: Equatable, Sendable {
    case waiting
    case claimed(clientPublicKey: Data)
    case completed
}

public struct ClientPairingClaim: Equatable, Sendable {
    public let sessionID: String
    public let computerID: String
    public let expiresAt: Int64
    public let hostPublicKey: Data
    public let privateKey: Data

    public init(
        sessionID: String,
        computerID: String,
        expiresAt: Int64,
        hostPublicKey: Data,
        privateKey: Data
    ) {
        self.sessionID = sessionID
        self.computerID = computerID
        self.expiresAt = expiresAt
        self.hostPublicKey = hostPublicKey
        self.privateKey = privateKey
    }
}

enum PairingKeyAgreement {
    static func makePrivateKey() -> Data {
        Curve25519.KeyAgreement.PrivateKey().rawRepresentation
    }

    static func publicKey(for privateKey: Data) throws -> Data {
        try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey)
            .publicKey.rawRepresentation
    }

    static func seal(
        secret: Data,
        hostPrivateKey: Data,
        clientPublicKey: Data,
        sessionID: String
    ) throws -> Data {
        let privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: hostPrivateKey)
        let publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: clientPublicKey)
        let key = try deriveKey(privateKey: privateKey, publicKey: publicKey, sessionID: sessionID)
        return try ChaChaPoly.seal(
            secret,
            using: key,
            authenticating: Data(sessionID.utf8)
        ).combined
    }

    static func open(
        envelope: Data,
        clientPrivateKey: Data,
        hostPublicKey: Data,
        sessionID: String
    ) throws -> Data {
        let privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: clientPrivateKey)
        let publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: hostPublicKey)
        let key = try deriveKey(privateKey: privateKey, publicKey: publicKey, sessionID: sessionID)
        return try ChaChaPoly.open(
            ChaChaPoly.SealedBox(combined: envelope),
            using: key,
            authenticating: Data(sessionID.utf8)
        )
    }

    private static func deriveKey(
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        publicKey: Curve25519.KeyAgreement.PublicKey,
        sessionID: String
    ) throws -> SymmetricKey {
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
        return shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("Pedals pairing code v2".utf8),
            sharedInfo: Data(sessionID.utf8),
            outputByteCount: 32
        )
    }
}
