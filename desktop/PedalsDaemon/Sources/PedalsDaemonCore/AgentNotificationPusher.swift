import CryptoKit
import Foundation
import PedalsKit

/// Turns agent updates (state transitions into waiting/error/done) into
/// visible pushes: seals the rich
/// content under the computer's notification key and hands the Worker only
/// `{category, sessionId, sealed}` (AGENT_MONITORING_DESIGN.md §6).
///
/// Delivery is fire-and-forget — a lost push costs one notification, and the
/// agent list itself still syncs over the E2EE channel. A per-agent floor
/// guards the APNs budget against pathological hook storms; legitimate
/// transitions are edge-triggered upstream and far apart.
public final class AgentNotificationPusher: @unchecked Sendable {
    public typealias Transport = @Sendable (
        _ category: AgentNotification.Category,
        _ sessionId: Int?,
        _ dedupeKey: String,
        _ sealed: Data
    ) async throws -> Void

    /// Minimum spacing between pushes for the same agent session.
    static let perAgentFloor: TimeInterval = 3
    /// Bounded so a dead service cannot pile up detached tasks.
    static let maxInFlight = 8

    private let lock = NSLock()
    private let computerID: String
    private let notificationKey: SymmetricKey
    private let transport: Transport
    private var lastPushAt: [String: Date] = [:]
    private var inFlight = 0

    public init(identity: HostIdentity, transport: Transport? = nil) {
        computerID = identity.computer.computerID
        notificationKey = AgentNotification.notificationKey(secret: identity.computer.secret)
        self.transport = transport ?? { category, sessionId, dedupeKey, sealed in
            try await PedalsServiceAPI(
                serviceURL: identity.computer.serviceURL
            ).sendAgentNotification(
                category: category,
                sessionId: sessionId,
                dedupeKey: dedupeKey,
                sealed: sealed,
                identity: identity
            )
        }
    }

    /// Called from AgentMonitor's queue; the network hop happens off it.
    public func push(_ info: AgentInfo, category: AgentNotification.Category) {
        lock.lock()
        let now = Date()
        if let last = lastPushAt[info.id],
           now.timeIntervalSince(last) < Self.perAgentFloor {
            lock.unlock()
            return
        }
        guard inFlight < Self.maxInFlight else {
            lock.unlock()
            return
        }
        lastPushAt[info.id] = now
        inFlight += 1
        lock.unlock()

        let content = AgentNotification.Content(
            agent: info.agent,
            category: category,
            message: info.message.map { String($0.prefix(AgentNotification.messageByteBudget)) },
            cwd: info.cwd.isEmpty ? nil : info.cwd,
            sessionId: info.sessionId
        )
        // The dedupe key makes Worker-side APNs retries idempotent; a new
        // transition (fresh updatedAt) is a new notification on purpose.
        let dedupeKey = "\(info.id):\(category.rawValue):\(Int(info.updatedAt))"
        let computerID = self.computerID
        let key = notificationKey
        let transport = self.transport
        Task.detached { [weak self] in
            defer { self?.finishOne() }
            do {
                let sealed = try AgentNotification.seal(
                    content, key: key, computerID: computerID
                )
                try await transport(category, content.sessionId, dedupeKey, sealed)
            } catch {
                FileHandle.standardError.write(
                    Data("agent update push failed: \(error)\n".utf8)
                )
            }
        }
    }

    private func finishOne() {
        lock.lock()
        inFlight -= 1
        lock.unlock()
    }
}
