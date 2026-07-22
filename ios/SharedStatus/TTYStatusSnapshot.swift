import Foundation

/// Per-state coding-agent aggregate counts for one computer. These are the
/// only agent-derived numbers the service sees (rich agent detail is
/// E2EE-only); `waiting` folds in error states. Running and waiting only —
/// done grows without bound and stays client-side.
public struct ComputerAgentCounts: Codable, Hashable, Sendable {
    public static let zero = ComputerAgentCounts(running: 0, waiting: 0)

    public var running: Int
    public var waiting: Int

    public init(running: Int, waiting: Int) {
        self.running = max(0, running)
        self.waiting = max(0, waiting)
    }
}

public struct ComputerTTYStatus: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var runningTTYCount: Int
    public var agents: ComputerAgentCounts
    public var online: Bool
    public var updatedAt: Date

    public init(
        id: String,
        name: String,
        runningTTYCount: Int,
        agents: ComputerAgentCounts = .zero,
        online: Bool,
        updatedAt: Date
    ) {
        self.id = id
        self.name = name
        self.runningTTYCount = max(0, runningTTYCount)
        self.agents = agents
        self.online = online
        self.updatedAt = updatedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            runningTTYCount: try container.decode(Int.self, forKey: .runningTTYCount),
            // Absent in snapshots cached before agent counts existed.
            agents: try container.decodeIfPresent(ComputerAgentCounts.self, forKey: .agents) ?? .zero,
            online: try container.decode(Bool.self, forKey: .online),
            updatedAt: try container.decode(Date.self, forKey: .updatedAt)
        )
    }
}

public struct TTYStatusSnapshot: Codable, Hashable, Sendable {
    public static let currentVersion = 2

    public var version: Int
    public var totalRunning: Int
    public var computers: [ComputerTTYStatus]
    public var updatedAt: Date
    public var sequence: UInt64
    public var stale: Bool

    public init(
        version: Int = currentVersion,
        totalRunning: Int,
        computers: [ComputerTTYStatus],
        updatedAt: Date,
        sequence: UInt64,
        stale: Bool = false
    ) {
        self.version = version
        self.totalRunning = max(0, totalRunning)
        self.computers = computers
        self.updatedAt = updatedAt
        self.sequence = sequence
        self.stale = stale
    }

    public static var empty: Self {
        .init(totalRunning: 0, computers: [], updatedAt: .distantPast, sequence: 0, stale: true)
    }

    public var onlineComputerCount: Int {
        computers.lazy.filter(\.online).count
    }

    public var offlineComputerCount: Int {
        computers.count - onlineComputerCount
    }

    public var agentsRunning: Int {
        computers.reduce(0) { $0 + $1.agents.running }
    }

    public var agentsWaiting: Int {
        computers.reduce(0) { $0 + $1.agents.waiting }
    }

}

public struct PedalsStatusCredential: Codable, Hashable, Sendable {
    public let serviceURL: URL
    public let clientID: String
    public let statusToken: String

    public init(serviceURL: URL, clientID: String, statusToken: String) {
        self.serviceURL = serviceURL
        self.clientID = clientID
        self.statusToken = statusToken
    }
}

public enum PedalsStatusConstants {
    public static let appGroup = "group.air.build.pedals"
    public static let phoneWidgetKind = "air.build.pedals.tty-count"
    public static let watchWidgetKind = "air.build.pedals.watch.tty-count"
}
