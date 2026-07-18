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
        if let context = WatchStatusContext(
            applicationContext: session.receivedApplicationContext
        ) {
            apply(context: context)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        guard activationState == .activated, error == nil else { return }
        guard let context = WatchStatusContext(
            applicationContext: session.receivedApplicationContext
        ) else { return }
        Task { @MainActor [weak self] in
            self?.apply(context: context)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        guard let context = WatchStatusContext(applicationContext: applicationContext) else {
            return
        }
        Task { @MainActor [weak self] in
            self?.apply(context: context)
        }
    }

    private func apply(context: WatchStatusContext) {
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
