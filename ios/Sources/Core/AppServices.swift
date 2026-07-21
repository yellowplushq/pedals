import Combine
import Foundation
import GhosttyTerminal
import PedalsKit
import WidgetKit

/// Composition root: one instance owns every long-lived object in the app.
@MainActor
final class AppServices {
    let preferences = TerminalPreferences()
    let pairingStore = PairingStore()
    let terminals: TerminalManager
    /// One controller per terminal view: TerminalSurfaceCoordinator installs
    /// itself as the controller's single onWakeup/shouldProcessWakeup closure,
    /// so views sharing a controller clobber each other's render wakeups
    /// (last one wins — hidden view suspends everyone). Matches the pattern
    /// in libghostty-spm's example apps.
    private var liveControllers = NSHashTable<TerminalController>.weakObjects()
    private var statusSubscriptions: Set<AnyCancellable> = []
    private var computerStatusSubscriptions: Set<AnyCancellable> = []
    private var statusRefreshTask: Task<Void, Never>?
    private let watchTerminalProvisioner = WatchTerminalProvisioner()
    private var watchTerminalSyncTask: Task<Void, Never>?

    init() {
        #if DEBUG
        let forceReset = ProcessInfo.processInfo.environment["PEDALS_RESET_PAIRING"] == "1"
        let storedServiceURL = try? pairingStore.loadClientIdentity()?.serviceURL
        if forceReset || storedServiceURL.map({ $0 != Self.pairingServiceURL }) == true {
            PairingStore.resetKeychainForUITesting()
            WatchTerminalProvisioner.resetKeychainForUITesting()
        }
        #endif
        terminals = TerminalManager(pairingStore: pairingStore)
        terminals.$computers
            .sink { [weak self] computers in
                self?.observeStatusChanges(in: computers)
                self?.synchronizeWatchTerminalContext()
                self?.scheduleStatusRefresh()
            }
            .store(in: &statusSubscriptions)
    }

    func startSystemSurfaces() {
        IOSWatchConnectivityBridge.shared.setTerminalContextRequestHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.synchronizeWatchTerminalContext()
            }
        }
        IOSWatchConnectivityBridge.shared.activate()
        TTYLiveActivityController.shared.startObservingPushTokens()
        PushEndpointRegistrar.requestFlush()
        installSharedCredential()
        reconcileBindings()
        scheduleStatusRefresh(immediate: true)
    }

    func refreshStatusSurfaces() {
        // Foregrounding is a durable retry opportunity after an extension was
        // suspended or a prior endpoint registration hit a transient failure.
        PushEndpointRegistrar.requestFlush()
        reconcileBindings()
        synchronizeWatchTerminalContext()
        scheduleStatusRefresh(immediate: true)
    }

    /// Retries server-side convergence to the phone's authoritative binding
    /// list, covering any unbind whose reconcile did not reach the service.
    private func reconcileBindings() {
        Task { @MainActor [pairingStore] in
            await pairingStore.reconcile()
        }
    }

    func makeTerminalController() -> TerminalController {
        let controller = TerminalController(
            configuration: preferences.terminalConfiguration(),
            theme: preferences.terminalTheme()
        )
        liveControllers.add(controller)
        return controller
    }

    /// The only pairing entry point: an 8-digit, server-issued, single-use code.
    func bind(code: PairingCode) async throws {
        try await terminals.addComputer(code: code, serviceURL: Self.pairingServiceURL)
        installSharedCredential()
        scheduleStatusRefresh(immediate: true)
    }

    private static var pairingServiceURL: URL {
        #if DEBUG
        if let value = ProcessInfo.processInfo.environment["PEDALS_SERVICE_URL"],
           let url = URL(string: value),
           url.scheme == "http",
           let host = url.host?.lowercased(),
           ["localhost", "127.0.0.1", "::1"].contains(host)
        {
            return url
        }
        #endif
        return PedalsServiceAPI.productionServiceURL
    }

    func applyTerminalAppearance() {
        for controller in liveControllers.allObjects {
            controller.setTheme(preferences.terminalTheme())
            controller.setTerminalConfiguration(preferences.terminalConfiguration())
        }
    }

    private func installSharedCredential() {
        let identity: ClientIdentity
        do {
            guard let storedIdentity = try pairingStore.loadClientIdentity() else {
                // Authoritative: this installation is unpaired.
                StatusSharedStore.removeCredential()
                IOSWatchConnectivityBridge.shared.setTerminalContext(
                    .init(clearedAtRevision: WatchTerminalContext.currentRevision)
                )
                return
            }
            identity = storedIdentity
        } catch {
            // A transient Keychain read failure is not evidence of unpairing;
            // keep the Watch's last-known-good credential.
            return
        }
        let credential = PedalsStatusCredential(
            serviceURL: identity.serviceURL,
            clientID: identity.clientID,
            statusToken: identity.statusToken
        )
        Task {
            await PedalsStatusRuntime.installCredential(credential)
            IOSWatchConnectivityBridge.shared.sendCurrentContext()
        }
        synchronizeWatchTerminalContext()
    }

    private func synchronizeWatchTerminalContext() {
        watchTerminalSyncTask?.cancel()
        let source: ClientIdentity
        let bindings: [ComputerBinding]
        do {
            guard let identity = try pairingStore.loadClientIdentity() else {
                // Authoritative: unpaired, so the Watch must not keep a
                // credential either.
                IOSWatchConnectivityBridge.shared.setTerminalContext(
                    .init(clearedAtRevision: WatchTerminalContext.currentRevision)
                )
                return
            }
            source = identity
            bindings = try pairingStore.loadAll()
        } catch {
            // Transient Keychain failure: keep the Watch's last-known-good
            // credential. The relay is the enforcement point for anything the
            // phone may since have revoked.
            return
        }

        watchTerminalSyncTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let context = try await watchTerminalProvisioner.context(
                    source: source,
                    bindings: bindings
                )
                guard !Task.isCancelled else { return }
                IOSWatchConnectivityBridge.shared.setTerminalContext(.init(context: context))
            } catch {
                // Provisioning needs the network; a failure here (offline,
                // service hiccup) must not revoke a Watch credential that
                // still works. The next foreground/bindings change retries,
                // and the relay rejects anything actually revoked.
            }
        }
    }

    private func observeStatusChanges(in computers: [ComputerConnection]) {
        computerStatusSubscriptions.removeAll()
        for computer in computers {
            computer.$sessions
                .combineLatest(computer.$hostOnline)
                .dropFirst()
                .sink { [weak self] _, _ in self?.scheduleStatusRefresh() }
                .store(in: &computerStatusSubscriptions)
        }
    }

    private func scheduleStatusRefresh(immediate: Bool = false) {
        statusRefreshTask?.cancel()
        statusRefreshTask = Task { @MainActor [weak self] in
            if !immediate {
                try? await Task.sleep(for: .milliseconds(350))
            }
            guard !Task.isCancelled, self != nil,
                  StatusSharedStore.credential() != nil
            else { return }
            do {
                let snapshot = try await PedalsStatusRuntime.refreshState()
                try await TTYLiveActivityController.shared.synchronize(with: snapshot)
                WidgetCenter.shared.reloadTimelines(
                    ofKind: PedalsStatusConstants.phoneWidgetKind
                )
                IOSWatchConnectivityBridge.shared.sendCurrentContext()
            } catch {
                // Widget timelines and APNs will retry; keep the last snapshot.
            }
        }
    }
}
