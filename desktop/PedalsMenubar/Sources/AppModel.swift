import AppKit
import SwiftUI

/// Relay connectivity, distilled from the daemon's `status` reply.
enum RelayState: Equatable {
    case daemonNotRunning
    case connecting
    case connected

    var indicatorOpacity: Double {
        switch self {
        case .daemonNotRunning: 0.28
        case .connecting: 0.58
        case .connected: 1
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
    static let onboardingCompletionKey = "completedDesktopOnboardingV2"
    static var defaultDaemonPath: String {
        if let bundledDaemon = Bundle.main.url(
            forResource: "pedals",
            withExtension: nil,
            subdirectory: nil
        ) {
            return bundledDaemon.path
        }

        // Xcode development builds do not embed the daemon. Keep the source-tree
        // fallback so the menu app remains convenient to run during development.
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("PedalsDaemon/.build/debug/pedals")
            .path
    }

    @Published private(set) var daemonReachable = false
    @Published private(set) var sessions: [SessionInfo] = []
    @Published private(set) var clientConnected = false
    @Published private(set) var relayState: RelayState = .daemonNotRunning
    @Published private(set) var pairingCode: String?
    @Published private(set) var pairingExpiresAt: Date?
    @Published private(set) var isLoadingPairingCode = false
    @Published private(set) var isStartingDaemon = false
    @Published private(set) var hasCompletedOnboarding: Bool
    @Published private(set) var managesDaemon = false
    @Published var lastError: String?

    private let client = DaemonClient()
    private var daemonProcess: Process?
    private var pairingTask: Task<Void, Never>?
    private var terminationObserver: (any NSObjectProtocol)?

    init() {
        hasCompletedOnboarding = UserDefaults.standard.bool(
            forKey: Self.onboardingCompletionKey
        )
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
            pairingCode = nil
            pairingExpiresAt = nil
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

    func fetchPairingCode() {
        pairingTask?.cancel()
        pairingCode = nil
        pairingExpiresAt = nil
        isLoadingPairingCode = true
        pairingTask = Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await client.pair()
                let code = response["code"]?.stringValue
                let expiresAt = response["expiresAt"]?.doubleValue
                guard !Task.isCancelled else { return }
                pairingCode = code
                pairingExpiresAt = expiresAt.map { Date(timeIntervalSince1970: $0) }
                if code == nil { lastError = "Daemon returned no pairing code" }
            } catch {
                guard !Task.isCancelled else { return }
                pairingCode = nil
                pairingExpiresAt = nil
                lastError = error.localizedDescription
            }
            isLoadingPairingCode = false
        }
    }

    func clearPairingCode() {
        pairingTask?.cancel()
        pairingTask = nil
        let shouldRevoke = pairingCode != nil || isLoadingPairingCode
        pairingCode = nil
        pairingExpiresAt = nil
        isLoadingPairingCode = false
        if shouldRevoke {
            Task { [client] in _ = try? await client.cancelPair() }
        }
    }

    func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: Self.onboardingCompletionKey)
        hasCompletedOnboarding = true
        clearPairingCode()
    }

    // MARK: Daemon lifecycle

    var daemonBinaryPath: String {
        UserDefaults.standard.string(forKey: Self.daemonPathKey) ?? Self.defaultDaemonPath
    }

    func startDaemon() {
        guard daemonProcess == nil, !daemonReachable else { return }
        isStartingDaemon = true
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
            isStartingDaemon = false
            lastError = "Could not start daemon: \(error.localizedDescription)"
        }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            await self?.refresh()
            self?.isStartingDaemon = false
        }
    }

    func stopDaemon() {
        daemonProcess?.terminate()
    }
}
