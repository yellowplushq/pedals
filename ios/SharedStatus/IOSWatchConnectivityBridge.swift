import Foundation
import WatchConnectivity

/// Phone-side transport for a read-only status credential and the freshest
/// cached count. Call `activate()` at launch and `sendCurrentContext()` after
/// credential, binding, or snapshot changes.
public final class IOSWatchConnectivityBridge: NSObject, WCSessionDelegate, @unchecked Sendable {
    public static let shared = IOSWatchConnectivityBridge()

    private override init() {
        super.init()
    }

    public func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    public func sendCurrentContext() {
        guard WCSession.isSupported(),
              let credential = StatusSharedStore.credential()
        else { return }
        let session = WCSession.default
        guard session.activationState == .activated,
              session.isPaired,
              session.isWatchAppInstalled
        else { return }
        let context = WatchStatusContext(
            credential: credential,
            snapshot: StatusSharedStore.snapshot()
        )
        try? session.updateApplicationContext(context.applicationContext)
    }

    public func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        guard activationState == .activated, error == nil else { return }
        sendCurrentContext()
    }

    public func sessionDidBecomeInactive(_ session: WCSession) {}

    public func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    public func sessionWatchStateDidChange(_ session: WCSession) {
        sendCurrentContext()
    }
}
