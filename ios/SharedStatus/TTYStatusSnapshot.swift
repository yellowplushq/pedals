import Foundation

public struct ComputerTTYStatus: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var runningTTYCount: Int
    public var online: Bool
    public var updatedAt: Date

    public init(
        id: String,
        name: String,
        runningTTYCount: Int,
        online: Bool,
        updatedAt: Date
    ) {
        self.id = id
        self.name = name
        self.runningTTYCount = max(0, runningTTYCount)
        self.online = online
        self.updatedAt = updatedAt
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
