import Foundation
import WatchConnectivity
import WidgetKit

@MainActor
final class WatchStatusBridge: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = WatchStatusBridge()

    private override init() {
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        applyDecoded(applicationContext: session.receivedApplicationContext)
    }

    /// `applicationContext` is the durable fallback, but it can represent an
    /// intermediate phone state. While both apps are reachable, ask for the
    /// phone's current value so a Watch reinstall or transient provisioning
    /// failure cannot leave an empty terminal context installed indefinitely.
    func requestCurrentContext() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return }

        session.sendMessage(
            [WatchTerminalContext.requestMessageKey: true],
            replyHandler: { [weak self] applicationContext in
                let statusContext = WatchStatusContext(
                    applicationContext: applicationContext
                )
                let carriesTerminalContext = applicationContext[
                    WatchTerminalContext.applicationContextPresenceKey
                ] as? Bool == true
                let terminalContext = WatchTerminalContext(
                    applicationContext: applicationContext
                )
                Task { @MainActor [weak self] in
                    self?.apply(
                        statusContext: statusContext,
                        carriesTerminalContext: carriesTerminalContext,
                        terminalContext: terminalContext
                    )
                }
            },
            errorHandler: nil
        )
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        guard activationState == .activated, error == nil else { return }
        let applicationContext = session.receivedApplicationContext
        let statusContext = WatchStatusContext(applicationContext: applicationContext)
        let carriesTerminalContext = applicationContext[
            WatchTerminalContext.applicationContextPresenceKey
        ] as? Bool == true
        let terminalContext = WatchTerminalContext(applicationContext: applicationContext)
        Task { @MainActor [weak self] in
            self?.apply(
                statusContext: statusContext,
                carriesTerminalContext: carriesTerminalContext,
                terminalContext: terminalContext
            )
            self?.requestCurrentContext()
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        let statusContext = WatchStatusContext(applicationContext: applicationContext)
        let carriesTerminalContext = applicationContext[
            WatchTerminalContext.applicationContextPresenceKey
        ] as? Bool == true
        let terminalContext = WatchTerminalContext(applicationContext: applicationContext)
        Task { @MainActor [weak self] in
            self?.apply(
                statusContext: statusContext,
                carriesTerminalContext: carriesTerminalContext,
                terminalContext: terminalContext
            )
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        guard session.isReachable else { return }
        Task { @MainActor [weak self] in
            self?.requestCurrentContext()
        }
    }

    private func applyDecoded(applicationContext: [String: Any]) {
        apply(
            statusContext: WatchStatusContext(applicationContext: applicationContext),
            carriesTerminalContext: applicationContext[
                WatchTerminalContext.applicationContextPresenceKey
            ] as? Bool == true,
            terminalContext: WatchTerminalContext(applicationContext: applicationContext)
        )
    }

    private func apply(
        statusContext context: WatchStatusContext?,
        carriesTerminalContext: Bool,
        terminalContext: WatchTerminalContext?
    ) {
        if carriesTerminalContext {
            WatchTerminalStore.shared.install(terminalContext)
        }
        guard let context else { return }

        // Render the companion's freshest snapshot immediately. Credential
        // installation and endpoint delivery use short durable transactions
        // off MainActor and must never stall the Watch UI on network I/O.
        StatusSharedStore.saveSnapshot(context.snapshot)
        WidgetCenter.shared.reloadTimelines(ofKind: PedalsStatusConstants.watchWidgetKind)
        Task { [context] in
            let changed = await StatusSharedStore.saveCredential(context.credential)
            if changed {
                // A client replacement resets the monotonic snapshot store.
                // Re-apply the new client's companion snapshot before doing
                // any network work so the Watch never waits on APNs setup.
                StatusSharedStore.saveSnapshot(context.snapshot)
                WidgetCenter.shared.reloadTimelines(
                    ofKind: PedalsStatusConstants.watchWidgetKind
                )
            }
            await PushEndpointRegistrar.flushPending()
            _ = try? await PedalsStatusRuntime.refreshState()
        }
    }
}
