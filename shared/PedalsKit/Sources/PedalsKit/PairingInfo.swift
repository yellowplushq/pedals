import Foundation
import Security

/// Pairing parameters exchanged via QR code / URL scheme (PROTOCOL.md §2):
///
///     pedals://pair?v=1&relay=wss%3A%2F%2F<relay-host>&room=<roomId>&s=<base64url(secret)>
public struct PairingInfo: Equatable, Sendable {
    public static let version = 1
    public static let roomIdLength = 32 // hex chars (128-bit)
    public static let secretByteCount = 32

    /// Relay WebSocket endpoint base URL (ws:// or wss://).
    public let relay: URL
    /// 32 lowercase hex chars.
    public let roomId: String
    /// 32 random bytes.
    public let secret: Data

    public enum ParseError: Error, Equatable {
        case invalidURL
        case unsupportedVersion(String)
        case missingParameter(String)
        case invalidRelay(String)
        case invalidRoomId(String)
        case invalidSecret
    }

    public init(relay: URL, roomId: String, secret: Data) throws {
        guard let scheme = relay.scheme?.lowercased(), scheme == "ws" || scheme == "wss",
              relay.host != nil
        else { throw ParseError.invalidRelay(relay.absoluteString) }
        guard roomId.count == Self.roomIdLength, roomId.allSatisfy(\.isHexDigit)
        else { throw ParseError.invalidRoomId(roomId) }
        guard secret.count == Self.secretByteCount else { throw ParseError.invalidSecret }
        self.relay = relay
        self.roomId = roomId.lowercased()
        self.secret = secret
    }

    /// Generates fresh pairing material (used by the desktop daemon).
    public static func generate(relay: URL) throws -> PairingInfo {
        try PairingInfo(
            relay: relay,
            roomId: randomBytes(count: roomIdLength / 2).map { String(format: "%02x", $0) }.joined(),
            secret: Data(randomBytes(count: secretByteCount))
        )
    }

    // MARK: URL

    public var url: URL {
        // Percent-encode strictly (unreserved chars only) so the relay URL's "://"
        // is escaped exactly as the spec's example shows.
        var query = "v=\(Self.version)"
        query += "&relay=\(Self.strictEncode(relay.absoluteString))"
        query += "&room=\(roomId)"
        query += "&s=\(secret.base64URLEncodedString())"
        return URL(string: "pedals://pair?\(query)")!
    }

    public init(url: URL) throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "pedals",
              components.host?.lowercased() == "pair",
              let items = components.queryItems
        else { throw ParseError.invalidURL }

        var params: [String: String] = [:]
        for item in items { params[item.name] = item.value }

        guard let v = params["v"] else { throw ParseError.missingParameter("v") }
        guard v == String(Self.version) else { throw ParseError.unsupportedVersion(v) }
        guard let relayString = params["relay"] else { throw ParseError.missingParameter("relay") }
        guard let relay = URL(string: relayString) else { throw ParseError.invalidRelay(relayString) }
        guard let room = params["room"] else { throw ParseError.missingParameter("room") }
        guard let s = params["s"] else { throw ParseError.missingParameter("s") }
        guard let secret = Data(base64URLEncoded: s) else { throw ParseError.invalidSecret }
        try self.init(relay: relay, roomId: room, secret: secret)
    }

    public init(urlString: String) throws {
        guard let url = URL(string: urlString) else { throw ParseError.invalidURL }
        try self.init(url: url)
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    private static func strictEncode(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: unreserved)!
    }

    private static func randomBytes(count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return bytes
    }
}

// MARK: - base64url

extension Data {
    /// base64url without padding (RFC 4648 §5).
    public func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Accepts base64url with or without padding.
    public init?(base64URLEncoded string: String) {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        self.init(base64Encoded: base64)
    }
}
