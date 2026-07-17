import AppKit
import SwiftUI

/// Relay connectivity, distilled from the daemon's `status` reply.
enum RelayState: Equatable {
    case daemonNotRunning
    case connecting
    case connected

    var color: Color {
        switch self {
        case .daemonNotRunning: .gray
        case .connecting: .orange
        case .connected: .green
        }
    }

    var label: String {
        switch self {
        case .daemonNotRunning: "Daemon not running"
        case .connecting: "Connecting to relay…"
        case .connected: "Relay connected"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let daemonPathKey = "daemonBinaryPath"
    static let defaultDaemonPath =
        "/Users/eyhn/Projects/yellowplus/pedals/desktop/PedalsDaemon/.build/debug/pedals"

    @Published private(set) var daemonReachable = false
    @Published private(set) var sessions: [SessionInfo] = []
    @Published private(set) var clientConnected = false
    @Published private(set) var relayState: RelayState = .daemonNotRunning
    @Published private(set) var pairingURL: String?
    @Published private(set) var managesDaemon = false
    @Published var lastError: String?

    private let client = DaemonClient()
    private var daemonProcess: Process?
    private var terminationObserver: (any NSObjectProtocol)?

    init() {
        // A spawned daemon is a child of this app; take it down when we quit.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.daemonProcess?.terminate()
            }
        }
    }

    // MARK: Polling

    /// Runs while the menu window is open; the surrounding `.task` cancels it on close.
    func pollWhileOpen() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(2))
        }
    }

    func refresh() async {
        do {
            let ls = try await client.ls()
            sessions = (ls["sessions"]?.arrayValue ?? []).compactMap(SessionInfo.init(json:))
            clientConnected = ls["client"]?.stringValue == "connected"
            daemonReachable = true
            lastError = nil
        } catch {
            daemonReachable = false
            sessions = []
            clientConnected = false
            relayState = .daemonNotRunning
            pairingURL = nil
            if case DaemonClientError.socketUnavailable = error {
                lastError = nil // expected when the daemon is stopped
            } else {
                lastError = error.localizedDescription
            }
            return
        }

        if let status = try? await client.status() {
            relayState = Self.relayState(from: status)
        } else {
            relayState = .connecting
        }
    }

    /// Tolerant read of the relay connection state from `status` output.
    private static func relayState(from status: JSONValue) -> RelayState {
        let connectedStates: Set<String> = ["connected", "open", "online"]
        for key in ["relay", "state", "relayState", "connection"] {
            if let value = status[key]?.stringValue,
                connectedStates.contains(value.lowercased()) {
                return .connected
            }
        }
        if status["connected"]?.boolValue == true { return .connected }
        return .connecting
    }

    // MARK: Session actions

    func newSession() {
        Task {
            do {
                _ = try await client.new()
                await refresh()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func closeSession(_ id: Int) {
        Task {
            do {
                try await client.kill(id: id)
                await refresh()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    // MARK: Pairing

    func fetchPairingURL() {
        Task {
            do {
                pairingURL = try await client.pair()["url"]?.stringValue
                if pairingURL == nil { lastError = "Daemon returned no pairing URL" }
            } catch {
                pairingURL = nil
                lastError = error.localizedDescription
            }
        }
    }

    func clearPairingURL() {
        pairingURL = nil
    }

    // MARK: Daemon lifecycle

    var daemonBinaryPath: String {
        UserDefaults.standard.string(forKey: Self.daemonPathKey) ?? Self.defaultDaemonPath
    }

    func startDaemon() {
        guard daemonProcess == nil, !daemonReachable else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: daemonBinaryPath)
        process.arguments = ["serve"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.daemonProcess = nil
                self?.managesDaemon = false
                await self?.refresh()
            }
        }
        do {
            try process.run()
            daemonProcess = process
            managesDaemon = true
            lastError = nil
        } catch {
            lastError = "Could not start daemon: \(error.localizedDescription)"
        }
        Task { await refresh() }
    }

    func stopDaemon() {
        daemonProcess?.terminate()
    }
}
