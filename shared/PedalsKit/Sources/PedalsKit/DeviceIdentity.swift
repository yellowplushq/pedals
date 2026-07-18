import Foundation

/// Long-lived E2EE material for one computer. The Worker stores the identity
/// and binding edge, but never this secret.
public struct ComputerBinding: Codable, Equatable, Sendable {
    public static let computerIDLength = 32
    public static let secretByteCount = 32

    public enum ValidationError: Error, Equatable {
        case invalidService(String)
        case invalidComputerID(String)
        case invalidSecretLength(Int)
    }

    public let serviceURL: URL
    public let computerID: String
    public let secret: Data

    public init(serviceURL: URL, computerID: String, secret: Data) throws {
        guard Self.isAllowedService(serviceURL) else {
            throw ValidationError.invalidService(serviceURL.absoluteString)
        }
        let normalizedID = computerID.lowercased()
        guard normalizedID.count == Self.computerIDLength,
              normalizedID.allSatisfy({ $0.isASCII && ($0.isNumber || ("a" ... "f").contains($0)) })
        else { throw ValidationError.invalidComputerID(computerID) }
        guard secret.count == Self.secretByteCount else {
            throw ValidationError.invalidSecretLength(secret.count)
        }
        self.serviceURL = serviceURL
        self.computerID = normalizedID
        self.secret = secret
    }

    public var relayURL: URL {
        var components = URLComponents(url: serviceURL, resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.query = nil
        components.fragment = nil
        return components.url!
    }

    private static func isAllowedService(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(),
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil
        else { return false }
        if scheme == "https" { return true }
        return scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)
    }
}

public struct HostIdentity: Codable, Equatable, Sendable {
    public let computer: ComputerBinding
    public let hostToken: String

    public init(computer: ComputerBinding, hostToken: String) {
        self.computer = computer
        self.hostToken = hostToken
    }
}

public struct ClientIdentity: Codable, Equatable, Sendable {
    public let serviceURL: URL
    public let clientID: String
    public let clientToken: String
    public let statusToken: String

    public init(
        serviceURL: URL,
        clientID: String,
        clientToken: String,
        statusToken: String
    ) {
        self.serviceURL = serviceURL
        self.clientID = clientID.lowercased()
        self.clientToken = clientToken
        self.statusToken = statusToken
    }
}

enum SecureRandom {
    static func data(count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0 ..< count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}

public extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded value: String) {
        guard value.allSatisfy({
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "=")
        }) else { return nil }
        let unpadded = value.replacingOccurrences(of: "=", with: "")
        let remainder = unpadded.count % 4
        guard remainder != 1 else { return nil }
        let normalized = unpadded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            + String(repeating: "=", count: remainder == 0 ? 0 : 4 - remainder)
        self.init(base64Encoded: normalized)
    }
}
