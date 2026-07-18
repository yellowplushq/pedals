import Foundation
import PedalsKit

/// Host end of the relay: one `control` RelayLink (session list, create/close)
/// plus one `session` RelayLink per listed session (replay + stdout out,
/// stdin/resize in). Each link is its own encrypted WebSocket with reconnect
/// (PROTOCOL.md §1); a client `hello` on a session link triggers a fresh
/// `replay` broadcast.
public final class RelayHostClient: @unchecked Sendable {
    public enum State: String, Sendable {
        case stopped
        case connecting
        case connected
    }

    private let queue = DispatchQueue(label: "air.build.pedals.relay")
    private let sessions: SessionManager
    private let hostName: String

    private var identity: HostIdentity
    private var started = false
    private var control: RelayLink?
    private var heartbeatTimer: DispatchSourceTimer?
    private var sessionLinks: [Int: RelayLink] = [:]
    /// Output offset already covered by the last `replay` sent per session;
    /// live stdout at or below it is not re-sent (bytes would double after the
    /// splice, see PROTOCOL.md §4).
    private var replayedThrough: [Int: UInt64] = [:]
    private var lastReportedAliveCount: Int?

    private var _state: State = .stopped
    /// A client hello arrived on the current control connection.
    private var _clientSeen = false

    public var state: State { queue.sync { _state } }
    public var clientConnected: Bool { queue.sync { _clientSeen } }
    public var computerID: String { queue.sync { identity.computer.computerID } }
    public var serviceURL: URL { queue.sync { identity.computer.serviceURL } }

    public init(identity: HostIdentity, sessions: SessionManager) {
        self.identity = identity
        self.sessions = sessions
        self.hostName = Self.sanitizedHostName(
            Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        )
    }

    private static func sanitizedHostName(_ value: String) -> String {
        let cleaned = value.filter { character in
            !character.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            })
        }.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = cleaned.isEmpty ? "Mac" : cleaned
        var result = ""
        var utf16Count = 0
        for character in candidate {
            let width = String(character).utf16.count
            guard utf16Count + width <= 128 else { break }
            result.append(character)
            utf16Count += width
        }
        return result.isEmpty ? "Mac" : result
    }

    // MARK: - Lifecycle

    public func start() {
        sessions.onEvent = { [weak self] event in
            self?.enqueue(sessionEvent: event)
        }
        queue.async { [self] in
            guard !started else { return }
            started = true
            connectAllLocked()
        }
    }

    private func enqueue(sessionEvent: SessionEvent) {
        queue.async { [weak self] in
            self?.handle(sessionEvent: sessionEvent)
        }
    }

    public func stop() {
        queue.sync {
            started = false
            teardownLocked()
            _state = .stopped
        }
    }

    /// Rotates the computer identity, E2EE secret, and host credential.
    public func update(identity: HostIdentity) {
        queue.async { [self] in
            self.identity = identity
            guard started else { return }
            teardownLocked()
            connectAllLocked()
        }
    }

    // MARK: - Links (all on `queue`)

    private func teardownLocked() {
        control?.stop()
        control = nil
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
        for link in sessionLinks.values { link.stop() }
        sessionLinks.removeAll()
        replayedThrough.removeAll()
        lastReportedAliveCount = nil
        _clientSeen = false
    }

    private func connectAllLocked() {
        _state = .connecting
        let link = RelayLink(
            computer: identity.computer,
            authorization: identity.hostToken,
            role: .host,
            principalID: identity.computer.computerID,
            channel: .control,
            hostName: hostName, callbackQueue: queue
        )
        link.onState = { [weak self] state in self?.controlStateChanged(state) }
        link.onFrame = { [weak self] frame in self?.handleControl(frame: frame) }
        control = link
        link.start()
        startHeartbeatLocked()
        reconcileSessionLinksLocked(with: sessions.list())
    }

    private func controlStateChanged(_ state: RelayLink.State) {
        switch state {
        case .connected:
            _state = .connected
            control?.send(.sessions(list: sessions.list()))
            reportHostStateLocked(force: true)
        case .connecting:
            _state = .connecting
            _clientSeen = false
        case .idle:
            break
        }
    }

    /// One session link per listed session — dead ones included, so a client
    /// switching to an exited terminal can still replay its final screen.
    private func reconcileSessionLinksLocked(with list: [SessionInfo]) {
        let ids = Set(list.map(\.id))
        for (id, link) in sessionLinks where !ids.contains(id) {
            link.stop()
            sessionLinks.removeValue(forKey: id)
            replayedThrough.removeValue(forKey: id)
        }
        for id in ids where sessionLinks[id] == nil {
            let link = RelayLink(
                computer: identity.computer,
                authorization: identity.hostToken,
                role: .host,
                principalID: identity.computer.computerID,
                channel: .session(sid: UInt32(id)),
                hostName: hostName, callbackQueue: queue
            )
            link.onFrame = { [weak self] frame in
                self?.handleSession(id: id, frame: frame)
            }
            sessionLinks[id] = link
            link.start()
        }
    }

    // MARK: - Control channel (on `queue`)

    private func handleControl(frame: Frame) {
        guard frame.type == .ctl, let message = try? frame.controlMessage() else {
            if frame.type == .ctl { control?.send(.err(msg: "malformed ctl payload")) }
            return
        }
        switch message {
        case .hello(let who, _, _, _, _, _):
            guard who == .client else { return }
            _clientSeen = true
            control?.send(.sessions(list: sessions.list()))
        case .requestSessions:
            control?.send(.sessions(list: sessions.list()))
        case .create(let cwd, let cols, let rows, let req):
            do {
                let id = try sessions.create(cwd: cwd, cols: cols, rows: rows)
                // The `sessions` broadcast is emitted by the SessionManager event.
                control?.send(.created(id: id, req: req))
            } catch {
                // Echo `req` so the requesting client can stop waiting and
                // surface the failure instead of timing out silently.
                control?.send(.err(msg: "create failed: \(error)", req: req))
            }
        case .close(let id):
            if !sessions.close(id: id) {
                control?.send(.err(msg: "no such session \(id)"))
            }
        case .sessions, .created, .title, .exit, .ready, .requestReplay:
            break // host→client only; ignore if mirrored back
        case .err(let msg, _):
            FileHandle.standardError.write(Data("client error: \(msg)\n".utf8))
        }
    }

    // MARK: - Session channels (on `queue`)

    private func handleSession(id: Int, frame: Frame) {
        // Defense in depth: per-channel keys already stop cross-channel
        // ciphertext at decrypt, so a mismatched sid on a data frame can only
        // be a bug — drop it rather than write to the wrong PTY.
        if (frame.type == .stdin || frame.type == .resize), frame.sessionId != UInt32(id) {
            return
        }
        switch frame.type {
        case .ctl:
            guard let message = try? frame.controlMessage() else { return }
            let requestsReplay: Bool
            switch message {
            case .hello(let who, _, _, _, _, _):
                requestsReplay = who == .client
            case .requestReplay:
                requestsReplay = true
            case .requestSessions:
                requestsReplay = false
            default:
                requestsReplay = false
            }
            guard requestsReplay,
                  let link = sessionLinks[id],
                  let snapshot = sessions.replaySnapshot(id: id)
            else { return }
            replayedThrough[id] = max(replayedThrough[id] ?? 0, snapshot.coversUpTo)
            link.send(.replay(sessionId: UInt32(id), data: snapshot.data))
        case .stdin:
            sessions.write(id: id, data: frame.payload)
        case .resize:
            guard let size = try? frame.resizeSize() else { return }
            sessions.resize(id: id, cols: size.cols, rows: size.rows)
        case .stdout, .replay:
            break // host→client only; ignore if mirrored back
        }
    }

    // MARK: - Session events (on `queue`)

    private func handle(sessionEvent event: SessionEvent) {
        guard started else { return }
        switch event {
        case .sessionsChanged(let list):
            control?.send(.sessions(list: list))
            reconcileSessionLinksLocked(with: list)
            reportHostStateLocked(force: false, sessions: list)
        case .output(let id, let data, let offset):
            guard let link = sessionLinks[id] else { return }
            let covered = replayedThrough[id] ?? 0
            let end = offset + UInt64(data.count)
            guard end > covered else { return } // fully inside the last replay
            let payload = offset >= covered ? data : data.suffix(Int(end - covered))
            link.send(.stdout(sessionId: UInt32(id), data: payload))
        case .title(let id, let title):
            control?.send(.title(id: id, title: title))
        case .exit(let id, let code):
            control?.send(.exit(id: id, code: code))
        }
    }

    // MARK: - Host state metadata (on `queue`)

    private struct HostState: Encodable {
        let type = "host-state"
        let aliveTTYCount: Int
        let hostName: String
    }

    private func startHeartbeatLocked() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 45, repeating: 45)
        timer.setEventHandler { [weak self] in
            self?.reportHostStateLocked(force: true)
        }
        timer.resume()
        heartbeatTimer?.cancel()
        heartbeatTimer = timer
    }

    private func reportHostStateLocked(force: Bool, sessions list: [SessionInfo]? = nil) {
        let count = (list ?? sessions.list()).lazy.filter(\.alive).count
        guard force || count != lastReportedAliveCount else { return }
        guard let data = try? JSONEncoder().encode(
            HostState(aliveTTYCount: count, hostName: hostName)
        ), let text = String(data: data, encoding: .utf8)
        else { return }
        control?.sendRelayText(text)
        lastReportedAliveCount = count
    }
}
