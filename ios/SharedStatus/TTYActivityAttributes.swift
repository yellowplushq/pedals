import ActivityKit
import Foundation

public struct TTYActivityAttributes: ActivityAttributes, Codable, Hashable, Sendable {
    public struct ContentState: Codable, Hashable, Sendable {
        public var totalRunning: Int
        public var onlineComputerCount: Int
        public var offlineComputerCount: Int
        public var updatedAt: Date
        public var sequence: UInt64

        public init(
            totalRunning: Int,
            onlineComputerCount: Int,
            offlineComputerCount: Int,
            updatedAt: Date,
            sequence: UInt64
        ) {
            self.totalRunning = max(0, totalRunning)
            self.onlineComputerCount = max(0, onlineComputerCount)
            self.offlineComputerCount = max(0, offlineComputerCount)
            self.updatedAt = updatedAt
            self.sequence = sequence
        }

        public init(snapshot: TTYStatusSnapshot) {
            self.init(
                totalRunning: snapshot.totalRunning,
                onlineComputerCount: snapshot.onlineComputerCount,
                offlineComputerCount: snapshot.offlineComputerCount,
                updatedAt: snapshot.updatedAt,
                sequence: snapshot.sequence
            )
        }
    }

    /// One aggregate activity represents every computer bound to this client.
    public let scope: String

    public init(scope: String = "all") {
        self.scope = scope
    }
}
