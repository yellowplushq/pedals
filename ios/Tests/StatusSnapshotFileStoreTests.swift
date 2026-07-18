import Foundation
import XCTest

@testable import Pedals

final class StatusSnapshotFileStoreTests: XCTestCase {
    private final class FailureBox: @unchecked Sendable {
        private let lock = NSLock()
        private var messages: [String] = []

        func append(_ error: Error) {
            lock.withLock { messages.append(String(describing: error)) }
        }

        var all: [String] {
            lock.withLock { messages }
        }
    }

    func testLowerSequenceCannotReplaceStoredSnapshot() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = StatusSnapshotFileStore(directory: directory)

        let newest = snapshot(sequence: 42)
        XCTAssertTrue(try store.save(newest).didWrite)

        let result = try store.save(snapshot(sequence: 7))
        XCTAssertFalse(result.didWrite)
        XCTAssertEqual(result.snapshot, newest)
        XCTAssertEqual(try store.load(), newest)
    }

    func testConcurrentIndependentStoreInstancesRemainMonotonic() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let failures = FailureBox()
        let highestSequence: UInt64 = 200

        // Each iteration constructs a new store and therefore opens an
        // independent descriptor, just as separate App Group processes do.
        // The final value must be the maximum regardless of completion order.
        DispatchQueue.concurrentPerform(iterations: Int(highestSequence)) { index in
            do {
                let store = StatusSnapshotFileStore(directory: directory)
                _ = try store.save(Self.snapshot(sequence: UInt64(index + 1)))
            } catch {
                failures.append(error)
            }
        }

        XCTAssertEqual(failures.all, [])
        let final = try StatusSnapshotFileStore(directory: directory).load()
        XCTAssertEqual(final?.sequence, highestSequence)
        XCTAssertEqual(final?.totalRunning, Int(highestSequence))
    }

    func testLiveActivityDeleteMutationKeepsActivityIdentityAndQuery() throws {
        let first = PendingPushEndpointMutation.delete(
            .iOSLiveActivityUpdate,
            activityId: "activity one/1"
        )
        let second = PendingPushEndpointMutation.delete(
            .iOSLiveActivityUpdate,
            activityId: "activity-two"
        )
        XCTAssertNotEqual(first.identity, second.identity)

        let encoded = try JSONEncoder().encode(first)
        let decoded = try JSONDecoder().decode(
            PendingPushEndpointMutation.self,
            from: encoded
        )
        XCTAssertEqual(decoded, first)

        let url = StatusAPIClient.pushEndpointURL(
            .iOSLiveActivityUpdate,
            activityId: first.activityId,
            baseURL: URL(string: "https://pedals.example/base/")!
        )
        let components = try XCTUnwrap(
            URLComponents(url: url, resolvingAgainstBaseURL: false)
        )
        XCTAssertEqual(
            components.path,
            "/base/v2/clients/me/push-endpoints/liveactivity-update"
        )
        XCTAssertEqual(
            components.queryItems,
            [URLQueryItem(name: "activityId", value: "activity one/1")]
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pedals-status-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private func snapshot(sequence: UInt64) -> TTYStatusSnapshot {
        Self.snapshot(sequence: sequence)
    }

    private static func snapshot(sequence: UInt64) -> TTYStatusSnapshot {
        .init(
            totalRunning: Int(sequence),
            computers: [],
            updatedAt: Date(timeIntervalSince1970: TimeInterval(sequence)),
            sequence: sequence
        )
    }
}
