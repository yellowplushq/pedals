import Foundation
import Observation
import PedalsKit

struct WatchTerminalID: Hashable, Sendable {
    let computerID: String
    let sessionID: Int
}

struct WatchTerminalDescriptor: Identifiable, Hashable, Sendable {
    let id: WatchTerminalID
    var computerName: String
    var title: String
    var cols: Int
    var rows: Int
    var alive: Bool
}

struct WatchTerminalComputer: Identifiable, Equatable, Sendable {
    let id: String
    var name: String
    var online: Bool
    var terminals: [WatchTerminalDescriptor]
}

@MainActor
@Observable
final class WatchTerminalStore {
    static let shared = WatchTerminalStore()

    private(set) var computers: [WatchTerminalComputer] = []
    private(set) var hasCredentials = false
    /// Changes only when terminal membership or an alive flag changes. Titles,
    /// host names, and TTY dimensions deliberately do not affect this value,
    /// so an ordinary redraw/resize never dismisses an open terminal.
    private(set) var terminalListRevision: UInt64 = 0

    @ObservationIgnored private var context: WatchTerminalContext?
    @ObservationIgnored private var connections: [String: WatchTerminalComputerConnection] = [:]
    @ObservationIgnored private var terminalSessions: [WatchTerminalID: WatchTerminalSession] = [:]
    @ObservationIgnored private var started = false

    private init() {
        if let stored = try? WatchTerminalCredentialStore.load() {
            replaceContext(stored, persist: false)
        }
    }

    func install(_ context: WatchTerminalContext?) {
        replaceContext(context, persist: true)
    }

    func start() {
        guard !started else { return }
        started = true
        for connection in connections.values { connection.start() }
    }

    func stop() {
        guard started else { return }
        started = false
        for connection in connections.values { connection.stop() }
        for session in terminalSessions.values { session.stop() }
    }

    func retryConnections() {
        guard started else {
            start()
            return
        }
        for connection in connections.values { connection.start() }
    }

    func descriptor(for id: WatchTerminalID) -> WatchTerminalDescriptor? {
        computers.lazy.flatMap(\.terminals).first { $0.id == id }
    }

    func session(for descriptor: WatchTerminalDescriptor) -> WatchTerminalSession? {
        if let existing = terminalSessions[descriptor.id] {
            existing.update(descriptor: descriptor)
            return existing
        }
        guard let context,
              let binding = context.bindings.first(where: {
                  $0.computerID == descriptor.id.computerID
              })
        else { return nil }

        let session = WatchTerminalSession(
            descriptor: descriptor,
            binding: binding,
            identity: context.identity
        )
        terminalSessions[descriptor.id] = session
        return session
    }

    private func replaceContext(_ context: WatchTerminalContext?, persist: Bool) {
        guard context != self.context else { return }

        for connection in connections.values { connection.stop() }
        for session in terminalSessions.values { session.stop() }
        connections.removeAll()
        terminalSessions.removeAll()
        self.context = context
        hasCredentials = context != nil

        if persist {
            try? WatchTerminalCredentialStore.save(context)
        }

        if let context {
            for binding in context.bindings {
                let connection = WatchTerminalComputerConnection(
                    binding: binding,
                    identity: context.identity
                )
                connection.onChange = { [weak self] in
                    self?.publishComputers()
                }
                connections[binding.computerID] = connection
                if started { connection.start() }
            }
        }
        publishComputers()
    }

    private func publishComputers() {
        let previousListState = Self.listState(computers)
        let updatedComputers = connections.values
            .map(\.snapshot)
            .sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        computers = updatedComputers

        if Self.listState(updatedComputers) != previousListState {
            terminalListRevision &+= 1
        }

        for descriptor in computers.lazy.flatMap(\.terminals) {
            terminalSessions[descriptor.id]?.update(descriptor: descriptor)
        }

        let liveTerminalIDs = Set(
            computers.lazy.flatMap(\.terminals).filter(\.alive).map(\.id)
        )
        let staleSessionIDs = terminalSessions.keys.filter {
            !liveTerminalIDs.contains($0)
        }
        for id in staleSessionIDs {
            terminalSessions.removeValue(forKey: id)?.stop()
        }
    }

    private static func listState(
        _ computers: [WatchTerminalComputer]
    ) -> [WatchTerminalID: Bool] {
        Dictionary(uniqueKeysWithValues: computers.lazy.flatMap(\.terminals).map {
            ($0.id, $0.alive)
        })
    }
}

@MainActor
private final class WatchTerminalComputerConnection {
    let binding: ComputerBinding
    var onChange: (() -> Void)?

    private let identity: ClientIdentity
    private var control: RelayLink?
    private var linkState: RelayLink.State = .idle
    private var hostName: String?
    private var hostOnline = false
    private var directoryRevision: UInt64?
    private var directoryEntries: [Int: Bool] = [:]
    private var peerSessions: [SessionInfo] = []
    private var visibleSessions: [SessionInfo] = []

    init(binding: ComputerBinding, identity: ClientIdentity) {
        self.binding = binding
        self.identity = identity
    }

    var snapshot: WatchTerminalComputer {
        let name = hostName ?? "Computer \(binding.computerID.prefix(6))"
        return WatchTerminalComputer(
            id: binding.computerID,
            name: name,
            online: hostOnline,
            terminals: visibleSessions.map { session in
                WatchTerminalDescriptor(
                    id: WatchTerminalID(
                        computerID: binding.computerID,
                        sessionID: session.id
                    ),
                    computerName: name,
                    title: session.title,
                    cols: session.cols,
                    rows: session.rows,
                    alive: session.alive
                )
            }
        )
    }

    func start() {
        guard control == nil else {
            control?.kick()
            return
        }
        let control = RelayLink(
            computer: binding,
            authorization: identity.clientToken,
            role: .client,
            principalID: identity.clientID,
            channel: .control
        )
        control.onState = { [weak self] state in
            MainActor.assumeIsolated { self?.handle(state: state) }
        }
        control.onFrame = { [weak self] frame in
            MainActor.assumeIsolated { self?.handle(frame: frame) }
        }
        control.onMetadata = { [weak self] metadata in
            MainActor.assumeIsolated { self?.handle(metadata: metadata) }
        }
        self.control = control
        control.start()
    }

    func stop() {
        control?.stop()
        control = nil
        linkState = .idle
    }

    private func handle(state: RelayLink.State) {
        linkState = state
        onChange?()
    }

    private func handle(frame: Frame) {
        guard frame.type == .ctl, let message = try? frame.controlMessage() else { return }
        switch message {
        case .hello(let who, _, _, _, _, let host):
            guard who == .host else { return }
            if let host, !host.isEmpty { hostName = host }
        case .sessions(let list):
            peerSessions = list
            applyDirectory()
        case .title(let id, let title):
            if let index = peerSessions.firstIndex(where: { $0.id == id }) {
                peerSessions[index].title = title
                applyDirectory()
            }
        case .exit(let id, _):
            if let index = peerSessions.firstIndex(where: { $0.id == id }) {
                peerSessions[index].alive = false
                applyDirectory()
            }
        case .ready, .requestReplay, .create, .created, .close, .err:
            break
        }
        onChange?()
    }

    private func handle(metadata: RelayMetadata) {
        guard case .terminalDirectory(let directory) = metadata else { return }
        if let directoryRevision, directory.revision <= directoryRevision { return }

        self.directoryRevision = directory.revision
        hostOnline = directory.online
        if let name = directory.hostName, !name.isEmpty { hostName = name }
        directoryEntries = directory.online
            ? Dictionary(uniqueKeysWithValues: directory.sessions.map { ($0.id, $0.alive) })
            : [:]
        if !directory.online { peerSessions.removeAll(keepingCapacity: true) }
        applyDirectory()
        onChange?()
    }

    private func applyDirectory() {
        guard hostOnline else {
            visibleSessions = []
            return
        }
        visibleSessions = peerSessions.compactMap { session in
            guard let alive = directoryEntries[session.id] else { return nil }
            var value = session
            value.alive = alive
            return value
        }
    }
}
