import Combine
import Foundation
import PedalsKit

/// Holds the host's session list and the locally active session id.
@MainActor
final class SessionStore {
    @Published private(set) var sessions: [SessionInfo] = []
    @Published private(set) var activeSessionId: Int?
    /// Exit codes reported via `exit` ctl messages, by session id.
    private(set) var exitCodes: [Int: Int] = [:]

    private var cancellables: Set<AnyCancellable> = []

    init(connection: ConnectionController) {
        connection.events
            .sink { [weak self] event in self?.handle(event) }
            .store(in: &cancellables)
        connection.$pairing
            .filter { $0 == nil }
            .sink { [weak self] _ in
                self?.sessions = []
                self?.activeSessionId = nil
                self?.exitCodes = [:]
            }
            .store(in: &cancellables)
    }

    func activate(_ id: Int) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        activeSessionId = id
    }

    func session(id: Int) -> SessionInfo? {
        sessions.first { $0.id == id }
    }

    private func handle(_ event: ConnectionController.HostEvent) {
        switch event {
        case let .sessions(list):
            sessions = list
            let ids = Set(list.map(\.id))
            exitCodes = exitCodes.filter { ids.contains($0.key) }
            if let activeSessionId, ids.contains(activeSessionId) { break }
            activeSessionId = (list.first { $0.alive } ?? list.first)?.id
        case let .created(id):
            activeSessionId = id
        case let .title(id, title):
            guard let index = sessions.firstIndex(where: { $0.id == id }) else { break }
            sessions[index].title = title
        case let .exit(id, code):
            exitCodes[id] = code
            guard let index = sessions.firstIndex(where: { $0.id == id }) else { break }
            sessions[index].alive = false
        case .stdout, .replay, .error:
            break
        }
    }
}
