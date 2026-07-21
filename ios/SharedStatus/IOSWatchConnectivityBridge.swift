import Foundation
import WatchConnectivity

/// Phone-side transport for the freshest status plus the relay/E2EE context
/// used by the paired Watch app. Call `activate()` at launch and
/// `sendCurrentContext()` after credential, binding, or snapshot changes.
public final class IOSWatchConnectivityBridge: NSObject, WCSessionDelegate, @unchecked Sendable {
    public static let shared = IOSWatchConnectivityBridge()

    private let contextLock = NSLock()
    private var terminalUpdate: WatchTerminalContextUpdate?
    private var terminalContextRequestHandler: (@Sendable () -> Void)?

    private override init() {
        super.init()
    }

    public func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    /// Invoked (on an arbitrary queue) whenever the Watch asks for the current
    /// context. The app uses this to re-run watch provisioning so a Watch that
    /// holds a rejected or missing credential converges without user action.
    public func setTerminalContextRequestHandler(_ handler: (@Sendable () -> Void)?) {
        contextLock.lock()
        terminalContextRequestHandler = handler
        contextLock.unlock()
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

    public func setTerminalContext(_ update: WatchTerminalContextUpdate) {
        contextLock.lock()
        terminalUpdate = update
        contextLock.unlock()
        sendCurrentContext()
    }

    private func currentTerminalUpdate() -> WatchTerminalContextUpdate? {
        contextLock.lock()
        defer { contextLock.unlock() }
        return terminalUpdate
    }

    private func currentApplicationContext() -> [String: Any] {
        var applicationContext = currentTerminalUpdate()?.applicationContext ?? [:]
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
        // The Watch asking is a repair opportunity: if the last provisioning
        // attempt failed (or its credential was revoked server-side), a fresh
        // sync produces a newer update that a later push delivers.
        contextLock.lock()
        let handler = terminalContextRequestHandler
        contextLock.unlock()
        handler?()
    }
}
