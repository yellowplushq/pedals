import AppKit
import PedalsDaemonCore
import PedalsKit
import SwiftUI

enum RelayState: Equatable {
    case starting
    case connecting
    case connected
    case unavailable

    var label: String {
        switch self {
        case .starting: "Starting Pedals…"
        case .connecting: "Connecting to service…"
        case .connected: "Connected"
        case .unavailable: "Service unavailable"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let pairedDeviceKey = "hasPairedDesktopClientV1"
    private static let legacyOnboardingKey = "completedDesktopOnboardingV2"
    private static let productionService = "https://pedals.air.build"

    @Published private(set) var serviceRunning = false
    @Published private(set) var sessions: [SessionInfo] = []
    @Published private(set) var clientConnected = false
    @Published private(set) var relayState: RelayState = .starting
    @Published private(set) var pairingCode: String?
    @Published private(set) var pairingExpiresAt: Date?
    @Published private(set) var isLoadingPairingCode = false
    @Published private(set) var isStartingService = false
    @Published private(set) var hasPairedDevice: Bool
    @Published var lastError: String?

    private var service: PedalsService?
    private var startupTask: Task<Void, Never>?
    private var monitoringTask: Task<Void, Never>?
    private var pairingTask: Task<Void, Never>?
    private var terminationObserver: (any NSObjectProtocol)?

    init() {
        let defaults = UserDefaults.standard
        let completedLegacyPairing = defaults.bool(forKey: Self.legacyOnboardingKey)
        hasPairedDevice = defaults.bool(forKey: Self.pairedDeviceKey) || completedLegacyPairing
        if completedLegacyPairing {
            defaults.set(true, forKey: Self.pairedDeviceKey)
            defaults.removeObject(forKey: Self.legacyOnboardingKey)
        }
        defaults.removeObject(forKey: "daemonBinaryPath")

        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pairingTask?.cancel()
                self?.monitoringTask?.cancel()
                self?.startupTask?.cancel()
                self?.service?.shutdown()
            }
        }

        startService()
    }

    // MARK: Service lifecycle

    func retryService() {
        startService()
    }

    private func startService() {
        guard service == nil, startupTask == nil else { return }
        isStartingService = true
        relayState = .starting
        lastError = nil
        let productionService = Self.productionService

        startupTask = Task { [weak self] in
            do {
                let service = try await Task.detached(priority: .userInitiated) {
                    let home = PedalsHome()
                    try home.save(config: .init(service: productionService))
                    let service = try PedalsService(home: home)
                    try service.start()
                    return service
                }.value

                guard let self, !Task.isCancelled else {
                    service.shutdown()
                    return
                }
                self.service = service
                serviceRunning = true
                isStartingService = false
                startupTask = nil
                await refresh()
                startMonitoring()
            } catch {
                guard let self, !Task.isCancelled else { return }
                monitoringTask?.cancel()
                monitoringTask = nil
                serviceRunning = false
                isStartingService = false
                relayState = .unavailable
                lastError = "Could not start Pedals: \(error.localizedDescription)"
                startupTask = nil
            }
        }
    }

    // MARK: Polling

    private func startMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                await refresh()
            }
        }
    }

    func refresh() async {
        guard let service else {
            sessions = []
            clientConnected = false
            return
        }

        let snapshot = await Task.detached(priority: .utility) {
            service.snapshot()
        }.value
        sessions = snapshot.sessions
        clientConnected = snapshot.clientConnected
        serviceRunning = true
        relayState = switch snapshot.relayState {
        case .stopped: .unavailable
        case .connecting: .connecting
        case .connected: .connected
        }

        if clientConnected, !hasPairedDevice {
            UserDefaults.standard.set(true, forKey: Self.pairedDeviceKey)
            hasPairedDevice = true
            finishPairingPresentation()
        }
    }

    // MARK: Session actions

    func closeSession(_ id: Int) {
        guard let service else { return }
        lastError = nil
        Task {
            let closed = await Task.detached(priority: .userInitiated) {
                service.closeSession(id: id)
            }.value
            await refresh()
            lastError = closed ? nil : "Session \(id) is no longer available"
        }
    }

    // MARK: Pairing

    func fetchPairingCode() {
        guard let service else { return }
        pairingTask?.cancel()
        pairingCode = nil
        pairingExpiresAt = nil
        isLoadingPairingCode = true

        pairingTask = Task { [weak self] in
            guard let self else { return }
            defer {
                isLoadingPairingCode = false
                pairingTask = nil
            }
            do {
                let invitation = try await Task.detached(priority: .userInitiated) {
                    try service.createPairingInvitation()
                }.value
                guard !Task.isCancelled else { return }
                pairingCode = invitation.code.digits
                pairingExpiresAt = invitation.expiresAt
                lastError = nil
            } catch {
                guard !Task.isCancelled else { return }
                pairingCode = nil
                pairingExpiresAt = nil
                lastError = "Could not create a connection code: \(error.localizedDescription)"
            }
        }
    }

    func clearPairingCode() {
        pairingTask?.cancel()
        pairingTask = nil
        let shouldRevoke = pairingCode != nil || isLoadingPairingCode
        pairingCode = nil
        pairingExpiresAt = nil
        isLoadingPairingCode = false
        guard shouldRevoke, let service else { return }
        Task.detached(priority: .utility) {
            service.cancelPairingInvitation()
        }
    }

    private func finishPairingPresentation() {
        pairingTask?.cancel()
        pairingTask = nil
        pairingCode = nil
        pairingExpiresAt = nil
        isLoadingPairingCode = false
    }
}
