import Foundation
import PedalsKit
import XCTest

@testable import PedalsDaemonCore

/// AgentNotificationPusher sealing, rate limiting, and RelayHostClient's aggregate
/// count derivation.
final class AgentNotificationPusherTests: XCTestCase {
    private final class Sent: @unchecked Sendable {
        struct Notification {
            let category: AgentNotification.Category
            let sessionId: Int?
            let dedupeKey: String
            let sealed: Data
        }

        private let lock = NSLock()
        private var notifications: [Notification] = []
        var all: [Notification] { lock.withLock { notifications } }
        func append(_ value: Notification) { lock.withLock { notifications.append(value) } }
    }

    private func makeIdentity() throws -> HostIdentity {
        HostIdentity(
            computer: try ComputerBinding(
                serviceURL: URL(string: "https://pedals.air.build")!,
                computerID: String(repeating: "c", count: 32),
                secret: Data(repeating: 0x42, count: 32)
            ),
            hostToken: "host-token"
        )
    }

    private func info(
        id: String = "a-1", state: AgentState = .waiting,
        message: String? = "Pick one", sessionId: Int? = 4, updatedAt: Double = 1000
    ) -> AgentInfo {
        AgentInfo(
            id: id, agent: "claude", state: state, cwd: "/tmp/p",
            message: message, sessionId: sessionId, updatedAt: updatedAt
        )
    }

    private func waitBriefly() {
        let expectation = expectation(description: "async transport")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
    }

    func testSealsContentTheClientCanOpen() throws {
        let identity = try makeIdentity()
        let sent = Sent()
        let pusher = AgentNotificationPusher(identity: identity) { category, sessionId, dedupeKey, sealed in
            sent.append(.init(
                category: category, sessionId: sessionId,
                dedupeKey: dedupeKey, sealed: sealed
            ))
        }
        pusher.push(info(), category: .waiting)
        waitBriefly()

        let notification = try XCTUnwrap(sent.all.first)
        XCTAssertEqual(notification.category, .waiting)
        XCTAssertEqual(notification.sessionId, 4)
        XCTAssertEqual(notification.dedupeKey, "a-1:waiting:1000")

        // The phone-side open path: notification key from the shared secret,
        // AAD bound to the computer id.
        let key = AgentNotification.notificationKey(secret: identity.computer.secret)
        let content = try AgentNotification.open(
            notification.sealed, key: key, computerID: identity.computer.computerID
        )
        XCTAssertEqual(content.agent, "claude")
        XCTAssertEqual(content.category, .waiting)
        XCTAssertEqual(content.message, "Pick one")
        XCTAssertEqual(content.cwd, "/tmp/p")
        XCTAssertEqual(content.sessionId, 4)
    }

    func testPerAgentFloorSwallowsBursts() throws {
        let sent = Sent()
        let pusher = AgentNotificationPusher(identity: try makeIdentity()) { category, _, _, _ in
            sent.append(.init(
                category: category, sessionId: nil, dedupeKey: "", sealed: Data()
            ))
        }
        pusher.push(info(updatedAt: 1000), category: .waiting)
        pusher.push(info(updatedAt: 1001), category: .done)
        pusher.push(info(id: "a-2", updatedAt: 1000), category: .waiting)
        waitBriefly()

        // Same agent within the floor: one push; a different agent passes.
        XCTAssertEqual(sent.all.count, 2)
        XCTAssertEqual(sent.all.map(\.category), [.waiting, .waiting])
    }

    func testAgentCountsFoldErrorIntoWaiting() {
        let list = [
            info(id: "a", state: .running),
            info(id: "b", state: .running),
            info(id: "c", state: .waiting),
            info(id: "d", state: .error),
            info(id: "e", state: .done),
        ]
        XCTAssertEqual(
            RelayHostClient.agentCounts(of: list),
            RelayMetadata.AgentCounts(running: 2, waiting: 2)
        )
        XCTAssertEqual(RelayHostClient.agentCounts(of: []), .zero)
    }
}
