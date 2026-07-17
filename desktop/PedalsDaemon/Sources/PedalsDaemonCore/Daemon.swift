import Foundation
import PedalsKit

/// The daemon: PTY session manager + relay host connection + unix control
/// socket. `pedals serve` constructs one and parks the main thread.
public final class Daemon: @unchecked Sendable {
    public enum DaemonError: Error, CustomStringConvertible {
        case notPaired

        public var description: String {
            """
            no pairing and no relay configured — run `pedals pair --reset` first, \
            or write {"relay":"wss://..."} to config.json
            """
        }
    }

    public let home: PedalsHome
    private let sessions: SessionManager
    private let relay: RelayHostClient
    private var controlServer: ControlServer?
    private let startedAt = Date()
    /// Serializes pairing regeneration against status/pair reads.
    private let pairingLock = NSLock()
    private var pairing: PairingInfo

    /// Loads (or, when a relay URL is configured, generates) the pairing and
    /// wires everything up. The control socket starts listening in `start()`.
    public init(home: PedalsHome = PedalsHome(), sessionOptions: SessionManager.Options = .init()) throws {
        self.home = home
        try home.ensureDirectoryExists()

        if let pairing = home.loadPairing() {
            self.pairing = pairing
        } else if let config = home.loadConfig(), let relayURL = URL(string: config.relay) {
            let pairing = try PairingInfo.generate(relay: relayURL)
            try home.save(pairing: pairing)
            self.pairing = pairing
        } else {
            throw DaemonError.notPaired
        }

        sessions = SessionManager(options: sessionOptions)
        relay = RelayHostClient(pairing: pairing, sessions: sessions)
    }

    public var pairingInfo: PairingInfo {
        pairingLock.lock()
        defer { pairingLock.unlock() }
        return pairing
    }

    public func start() throws {
        controlServer = try ControlServer(path: home.socketPath) { [weak self] request in
            self?.handle(request) ?? .error("daemon shutting down")
        }
        relay.start()
    }

    public func shutdown() {
        controlServer?.stop()
        controlServer = nil
        relay.stop()
        sessions.closeAll()
    }

    // MARK: - Control commands (PROTOCOL.md §5)

    private func handle(_ request: ControlRequest) -> ControlResponse {
        switch request.cmd {
        case "ls":
            return .ok([
                "sessions": .array(sessions.list().map(Self.encode(session:))),
                "client": .string(relay.clientConnected ? "connected" : "none"),
                "relay": .string(relay.relayURL.absoluteString),
            ])

        case "new":
            do {
                let id = try sessions.create()
                return .ok(["id": .int(id)])
            } catch {
                return .error("create failed: \(error)")
            }

        case "kill":
            guard let id = request.id else { return .error("kill requires \"id\"") }
            guard sessions.close(id: id) else { return .error("no such session \(id)") }
            return .ok([:])

        case "pair":
            do {
                let info = try currentOrRegeneratedPairing(reset: request.reset == true)
                return .ok(["url": .string(info.url.absoluteString)])
            } catch {
                return .error("pair failed: \(error)")
            }

        case "status":
            let state = relay.state
            return .ok([
                "relay": .string(relay.relayURL.absoluteString),
                "state": .string(state == .connected ? "connected" : "connecting"),
                "connected": .bool(state == .connected),
                "client": .string(relay.clientConnected ? "connected" : "none"),
                "room": .string(relay.roomId),
                "uptime": .double(Date().timeIntervalSince(startedAt).rounded()),
            ])

        default:
            return .error("unknown cmd \"\(request.cmd)\"")
        }
    }

    private func currentOrRegeneratedPairing(reset: Bool) throws -> PairingInfo {
        pairingLock.lock()
        defer { pairingLock.unlock() }
        guard reset else { return pairing }
        let relayURL = home.loadConfig().flatMap { URL(string: $0.relay) } ?? pairing.relay
        let fresh = try PairingInfo.generate(relay: relayURL)
        try home.save(pairing: fresh)
        pairing = fresh
        relay.update(pairing: fresh)
        return fresh
    }

    private static func encode(session: SessionInfo) -> ControlValue {
        .object([
            "id": .int(session.id),
            "title": .string(session.title),
            "cwd": .string(session.cwd),
            "rows": .int(session.rows),
            "cols": .int(session.cols),
            "createdAt": .double(session.createdAt),
            "alive": .bool(session.alive),
        ])
    }
}
