import Combine
import Foundation
import PedalsKit

/// One bound computer: the long-lived `control` RelayLink to its room.
/// Publishes the daemon's session list, machine name, and connection state;
/// hands out per-terminal session links (see `TerminalManager`'s pool).
@MainActor
final class ComputerConnection {
    enum Event {
        /// Broadcast reply to a `create`; `req` says whose request it was.
        case created(id: Int, req: UInt32?)
        case exit(id: Int, code: Int)
        /// Daemon-reported failure; `req` ties it to one of our creates.
        case error(msg: String, req: UInt32?)
    }

    let binding: ComputerBinding
    private let clientID: String
    private let clientToken: String
    /// Stable server-issued identity.
    var id: String { binding.computerID }

    @Published private(set) var linkState: RelayLink.State = .idle
    /// Daemon machine name from its `hello`; sticky across reconnects.
    @Published private(set) var hostName: String?
    /// The daemon's socket is attached at the relay (presence notice), or —
    /// before the first notice arrives — any decrypted host frame was seen.
    @Published private(set) var hostOnline = false
    @Published private(set) var sessions: [SessionInfo] = []
    @Published private(set) var roundTripTime: TimeInterval?

    let events = PassthroughSubject<Event, Never>()

    private let control: RelayLink

    var displayName: String {
        hostName ?? "Computer \(binding.computerID.prefix(6))"
    }

    init(binding: ComputerBinding, clientID: String, clientToken: String) {
        self.binding = binding
        self.clientID = clientID
        self.clientToken = clientToken
        control = RelayLink(
            computer: binding,
            authorization: clientToken,
            role: .client,
            principalID: clientID,
            channel: .control
        )
        control.onState = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.linkState = state
                if case .connecting = state {
                    self.hostOnline = false
                    self.roundTripTime = nil
                }
            }
        }
        control.onFrame = { [weak self] frame in
            MainActor.assumeIsolated { self?.handle(frame: frame) }
        }
        control.onRoundTrip = { [weak self] rtt in
            MainActor.assumeIsolated { self?.roundTripTime = rtt }
        }
        // The relay pushes host attach/detach for our channel; without it a
        // dead daemon would look online forever (our own socket stays up).
        control.onPeerPresence = { [weak self] online in
            MainActor.assumeIsolated {
                guard let self, self.hostOnline != online else { return }
                self.hostOnline = online
            }
        }
    }

    func start() {
        control.start()
    }

    func stop() {
        control.stop()
    }

    /// Reconnect immediately (app foregrounded / connectivity change).
    func kick() {
        control.kick()
    }

    // MARK: - Requests

    func createSession(cwd: String?, cols: Int, rows: Int, req: UInt32) {
        control.send(.create(cwd: cwd, cols: cols, rows: rows, req: req))
    }

    func closeSession(id: Int) {
        control.send(.close(id: id))
    }

    /// A fresh (not yet started) data link for one of this computer's sessions.
    func makeSessionLink(sid: Int) -> RelayLink {
        RelayLink(
            computer: binding,
            authorization: clientToken,
            role: .client,
            principalID: clientID,
            channel: .session(sid: UInt32(sid))
        )
    }

    // MARK: - Control frames

    private func handle(frame: Frame) {
        // Any frame that decrypts with the host's key proves the host is
        // online, even when we joined after its hello (the relay never queues).
        // Guard the assignment: @Published emits on every set, so an
        // unconditional `= true` would republish on every control frame and, e.g.,
        // rebuild the Settings list (cancelling an in-progress swipe) constantly.
        if !hostOnline { hostOnline = true }
        guard frame.type == .ctl, let message = try? frame.controlMessage() else { return }
        switch message {
        case .hello(let who, _, _, _, _, let host):
            guard who == .host else { break }
            if let host, !host.isEmpty { hostName = host }
        case .sessions(let list):
            sessions = list
        case .created(let id, let req):
            events.send(.created(id: id, req: req))
        case .title(let id, let title):
            // The daemon also rebroadcasts `sessions` on title changes; this
            // just applies it without waiting for the full list.
            guard let index = sessions.firstIndex(where: { $0.id == id }) else { break }
            sessions[index].title = title
        case .exit(let id, let code):
            if let index = sessions.firstIndex(where: { $0.id == id }) {
                sessions[index].alive = false
            }
            events.send(.exit(id: id, code: code))
        case .err(let msg, let req):
            events.send(.error(msg: msg, req: req))
        case .create, .close, .ready, .requestReplay:
            break // client→host only; ignore if mirrored back
        }
    }
}
