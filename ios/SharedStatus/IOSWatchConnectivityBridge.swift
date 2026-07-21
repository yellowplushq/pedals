import Foundation
import WatchConnectivity

/// Phone-side transport for the freshest status plus the relay/E2EE context
/// used by the paired Watch app. Call `activate()` at launch and
/// `sendCurrentContext()` after credential, binding, or snapshot changes.
public final class IOSWatchConnectivityBridge: NSObject, WCSessionDelegate, @unchecked Sendable {
    public static let shared = IOSWatchConnectivityBridge()

    private let contextLock = NSLock()
    private var terminalContext: WatchTerminalContext?

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
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated,
              session.isPaired,
              session.isWatchAppInstalled
        else { return }

        try? session.updateApplicationContext(currentApplicationContext())
    }

    public func setTerminalContext(_ context: WatchTerminalContext?) {
        contextLock.lock()
        terminalContext = context
        contextLock.unlock()
        sendCurrentContext()
    }

    private func currentTerminalContext() -> WatchTerminalContext? {
        contextLock.lock()
        defer { contextLock.unlock() }
        return terminalContext
    }

    private func currentApplicationContext() -> [String: Any] {
        var applicationContext = WatchTerminalContext.applicationContext(
            currentTerminalContext()
        )
        if let credential = StatusSharedStore.credential() {
            let context = WatchStatusContext(
                credential: credential,
                snapshot: StatusSharedStore.snapshot()
            )
            applicationContext.merge(context.applicationContext) { _, new in new }
        }
        return applicationContext
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

    public func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        guard message[WatchTerminalContext.requestMessageKey] as? Bool == true else {
            replyHandler([:])
            return
        }
        replyHandler(currentApplicationContext())
    }
}
