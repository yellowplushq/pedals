import ActivityKit
import Foundation

public struct TTYActivityAttributes: ActivityAttributes, Codable, Hashable, Sendable {
    public struct ContentState: Codable, Hashable, Sendable {
        public var totalRunning: Int
        /// Coding-agent aggregates. Optional-decoded so pushes from a relay
        /// that predates agent counts still parse (ActivityKit decodes
        /// content-state strictly otherwise).
        public var agentsRunning: Int
        public var agentsWaiting: Int
        public var agentsDone: Int
        public var recentAgentComputerID: String?
        public var recentAgentState: String?
        public var recentAgentUpdatedAt: Date?
        public var recentAgentSealed: String?
        public var onlineComputerCount: Int
        public var offlineComputerCount: Int
        public var updatedAt: Date
        public var sequence: UInt64

        public init(
            totalRunning: Int,
            agentsRunning: Int = 0,
            agentsWaiting: Int = 0,
            agentsDone: Int = 0,
            recentAgentComputerID: String? = nil,
            recentAgentState: String? = nil,
            recentAgentUpdatedAt: Date? = nil,
            recentAgentSealed: String? = nil,
            onlineComputerCount: Int,
            offlineComputerCount: Int,
            updatedAt: Date,
            sequence: UInt64
        ) {
            self.totalRunning = max(0, totalRunning)
            self.agentsRunning = max(0, agentsRunning)
            self.agentsWaiting = max(0, agentsWaiting)
            self.agentsDone = max(0, agentsDone)
            self.recentAgentComputerID = recentAgentComputerID
            self.recentAgentState = recentAgentState
            self.recentAgentUpdatedAt = recentAgentUpdatedAt
            self.recentAgentSealed = recentAgentSealed
            self.onlineComputerCount = max(0, onlineComputerCount)
            self.offlineComputerCount = max(0, offlineComputerCount)
            self.updatedAt = updatedAt
            self.sequence = sequence
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                totalRunning: try container.decode(Int.self, forKey: .totalRunning),
                agentsRunning: try container.decodeIfPresent(Int.self, forKey: .agentsRunning) ?? 0,
                agentsWaiting: try container.decodeIfPresent(Int.self, forKey: .agentsWaiting) ?? 0,
                agentsDone: try container.decodeIfPresent(Int.self, forKey: .agentsDone) ?? 0,
                recentAgentComputerID: try container.decodeIfPresent(String.self, forKey: .recentAgentComputerID),
                recentAgentState: try container.decodeIfPresent(String.self, forKey: .recentAgentState),
                recentAgentUpdatedAt: try container.decodeIfPresent(Date.self, forKey: .recentAgentUpdatedAt),
                recentAgentSealed: try container.decodeIfPresent(String.self, forKey: .recentAgentSealed),
                onlineComputerCount: try container.decode(Int.self, forKey: .onlineComputerCount),
                offlineComputerCount: try container.decode(Int.self, forKey: .offlineComputerCount),
                updatedAt: try container.decode(Date.self, forKey: .updatedAt),
                sequence: try container.decode(UInt64.self, forKey: .sequence)
            )
        }

        public init(snapshot: TTYStatusSnapshot) {
            self.init(
                totalRunning: snapshot.totalRunning,
                agentsRunning: snapshot.agentsRunning,
                agentsWaiting: snapshot.agentsWaiting,
                agentsDone: snapshot.agentsDone,
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
