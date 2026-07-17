import ArgumentParser
import Darwin
import Foundation
import PedalsDaemonCore
import PedalsKit

@main
struct PedalsCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pedals",
        abstract: "Pedals desktop daemon — remote terminal host.",
        subcommands: [Serve.self, Ls.self, New.self, Kill.self, Pair.self, Status.self]
    )
}

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("pedals: \(message)\n".utf8))
    Foundation.exit(1)
}

// MARK: - serve

struct Serve: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run the daemon in the foreground (PTY host + relay connection)."
    )

    @Option(help: "Relay WebSocket URL; written to config.json for future runs.")
    var relay: String?

    func run() throws {
        let home = PedalsHome()
        if let relay {
            guard let url = URL(string: relay),
                  url.scheme == "ws" || url.scheme == "wss"
            else { fail("--relay must be a ws:// or wss:// URL") }
            try home.save(config: .init(relay: url.absoluteString))
        }

        let daemon: Daemon
        do {
            daemon = try Daemon(home: home)
        } catch {
            fail("\(error)")
        }
        try daemon.start()

        print("pedals daemon started")
        print("  socket:  \(home.socketPath)")
        print("  relay:   \(daemon.pairingInfo.relay.absoluteString)")
        print("  room:    \(daemon.pairingInfo.roomId)")
        print("pair from iOS with: pedals pair")

        // Park the main thread; SIGINT/SIGTERM shut down cleanly.
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        signal(SIGPIPE, SIG_IGN)
        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        for source in [sigint, sigterm] {
            source.setEventHandler {
                daemon.shutdown()
                Foundation.exit(0)
            }
            source.resume()
        }
        dispatchMain()
    }
}

// MARK: - socket-backed subcommands

struct Ls: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List sessions.")

    func run() throws {
        let reply = try roundTripOrFail(["cmd": "ls"])
        let sessions = reply["sessions"] as? [[String: Any]] ?? []
        let client = reply["client"] as? String ?? "none"
        let relay = reply["relay"] as? String ?? "?"
        if sessions.isEmpty {
            print("no sessions")
        }
        for session in sessions {
            let id = session["id"] as? Int ?? 0
            let title = session["title"] as? String ?? ""
            let cwd = session["cwd"] as? String ?? ""
            let alive = session["alive"] as? Bool ?? false
            let cols = session["cols"] as? Int ?? 0
            let rows = session["rows"] as? Int ?? 0
            print("[\(id)] \(alive ? "live " : "exited") \(cols)x\(rows)  \(title)  (\(cwd))")
        }
        print("client: \(client)   relay: \(relay)")
    }
}

struct New: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Create a new session.")

    func run() throws {
        let reply = try roundTripOrFail(["cmd": "new"])
        print("created session \(reply["id"] as? Int ?? -1)")
    }
}

struct Kill: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Close a session.")

    @Argument(help: "Session id (see `pedals ls`).")
    var id: Int

    func run() throws {
        _ = try roundTripOrFail(["cmd": "kill", "id": id])
        print("closed session \(id)")
    }
}

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show relay connection status.")

    func run() throws {
        let reply = try roundTripOrFail(["cmd": "status"])
        print("relay:  \(reply["relay"] as? String ?? "?") (\(reply["state"] as? String ?? "?"))")
        print("room:   \(reply["room"] as? String ?? "?")")
        print("client: \(reply["client"] as? String ?? "none")")
        print("uptime: \(Int(reply["uptime"] as? Double ?? 0))s")
    }
}

struct Pair: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show the pairing QR code and pedals:// URL."
    )

    @Flag(help: "Generate a fresh room and secret (invalidates the old pairing).")
    var reset = false

    @Option(help: "Relay WebSocket URL; written to config.json for future runs.")
    var relay: String?

    func run() throws {
        let home = PedalsHome()
        if let relay {
            guard let url = URL(string: relay),
                  url.scheme == "ws" || url.scheme == "wss"
            else { fail("--relay must be a ws:// or wss:// URL") }
            try home.save(config: .init(relay: url.absoluteString))
        }

        // Prefer the running daemon (it reconnects to the new room on reset);
        // fall back to operating on ~/.pedals directly when it is not running.
        let url: String
        if let reply = try? ControlClient.roundTrip(
            socketPath: home.socketPath, request: ["cmd": "pair", "reset": reset]
        ), reply["ok"] as? Bool == true, let replyURL = reply["url"] as? String {
            url = replyURL
        } else {
            url = try localPairingURL(home: home)
        }

        print(try QRRenderer.ansi(text: url))
        print("Scan the QR from the Pedals iOS app, or open this URL on the device:")
        print(url)
    }

    private func localPairingURL(home: PedalsHome) throws -> String {
        if !reset, let existing = home.loadPairing() {
            return existing.url.absoluteString
        }
        let relayURL = home.loadConfig().flatMap { URL(string: $0.relay) }
            ?? home.loadPairing()?.relay
        guard let relayURL else {
            fail("no relay configured — pass --relay wss://<host> once, or edit \(home.configURL.path)")
        }
        let pairing = try PairingInfo.generate(relay: relayURL)
        try home.save(pairing: pairing)
        return pairing.url.absoluteString
    }
}

// MARK: - helpers

private func roundTripOrFail(_ request: [String: Any]) throws -> [String: Any] {
    let home = PedalsHome()
    let reply: [String: Any]
    do {
        reply = try ControlClient.roundTrip(socketPath: home.socketPath, request: request)
    } catch {
        fail("\(error)")
    }
    guard reply["ok"] as? Bool == true else {
        fail(reply["err"] as? String ?? "daemon reported an error")
    }
    return reply
}
