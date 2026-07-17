import Foundation
import PedalsKit

/// `~/.pedals` — config, pairing, and control-socket paths (PROTOCOL.md §2/§5).
/// The directory can be overridden with the `PEDALS_HOME` environment variable
/// (used by tests and by CI to avoid touching the real home directory).
public struct PedalsHome: Sendable {
    public let directory: URL

    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else if let override = ProcessInfo.processInfo.environment["PEDALS_HOME"],
                  !override.isEmpty {
            self.directory = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            self.directory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".pedals", isDirectory: true)
        }
    }

    public var configURL: URL { directory.appendingPathComponent("config.json") }
    public var pairingURL: URL { directory.appendingPathComponent("pairing.json") }
    public var socketPath: String { directory.appendingPathComponent("pedals.sock").path }

    public func ensureDirectoryExists() throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    // MARK: - config.json

    /// `{"relay": "wss://..."}` — the relay endpoint used when generating pairings.
    public struct Config: Codable, Sendable {
        public var relay: String

        public init(relay: String) { self.relay = relay }
    }

    public func loadConfig() -> Config? {
        guard let data = try? Data(contentsOf: configURL) else { return nil }
        return try? JSONDecoder().decode(Config.self, from: data)
    }

    public func save(config: Config) throws {
        try ensureDirectoryExists()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(config).write(to: configURL, options: .atomic)
    }

    // MARK: - pairing.json (mode 0600 per PROTOCOL.md §2)

    private struct StoredPairing: Codable {
        var url: String
    }

    public func loadPairing() -> PairingInfo? {
        guard let data = try? Data(contentsOf: pairingURL),
              let stored = try? JSONDecoder().decode(StoredPairing.self, from: data)
        else { return nil }
        return try? PairingInfo(urlString: stored.url)
    }

    public func save(pairing: PairingInfo) throws {
        try ensureDirectoryExists()
        let data = try JSONEncoder().encode(StoredPairing(url: pairing.url.absoluteString))
        try data.write(to: pairingURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: pairingURL.path
        )
    }
}
