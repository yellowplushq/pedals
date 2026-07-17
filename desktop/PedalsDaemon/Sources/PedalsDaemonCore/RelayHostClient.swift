import Foundation
import PedalsKit

/// Host end of the relay connection: WSS to `/v1/room/:roomId?role=host`, E2EE
/// via `SecureChannel`, reconnect with exponential backoff, and translation
/// between the client's ctl/stdin/resize frames and `SessionManager` calls.
public final class RelayHostClient: NSObject, @unchecked Sendable {
    public enum State: String, Sendable {
        case stopped
        case connecting
        case connected
    }

    private let queue = DispatchQueue(label: "app.yellowplus.pedals.relay")
    private let sessions: SessionManager

    private var pairing: PairingInfo
    private var urlSession: URLSession!
    private var socket: URLSessionWebSocketTask?
    private var channel: SecureChannel?
    private var reconnectAttempt = 0
    private var reconnectWork: DispatchWorkItem?
    /// Bumped on every (re)connect; callbacks from stale sockets are ignored.
    private var generation = 0
    private var started = false

    private var _state: State = .stopped
    private var _clientConnected = false
    /// connEpoch of the client connection we last accepted a hello from.
    private var clientConnEpoch: UInt32?
    /// Sessions the current client attached to, with the output offset already
    /// covered by the replay snapshot (bytes at or below it are not re-sent).
    private var attached: [Int: UInt64] = [:]

    public var state: State { queue.sync { _state } }
    public var clientConnected: Bool { queue.sync { _clientConnected } }
    public var roomId: String { queue.sync { pairing.roomId } }
    public var relayURL: URL { queue.sync { pairing.relay } }

    public init(pairing: PairingInfo, sessions: SessionManager) {
        self.pairing = pairing
        self.sessions = sessions
        super.init()
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = false
        urlSession = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    // MARK: - Lifecycle

    public func start() {
        sessions.onEvent = { [weak self] event in
            self?.queue.async { self?.handle(sessionEvent: event) }
        }
        queue.async { [self] in
            guard !started else { return }
            started = true
            reconnectAttempt = 0
            connectLocked()
        }
    }

    public func stop() {
        queue.sync {
            started = false
            teardownLocked()
            _state = .stopped
        }
    }

    /// Re-pair: tear down and reconnect to a (possibly new) room.
    public func update(pairing: PairingInfo) {
        queue.async { [self] in
            self.pairing = pairing
            guard started else { return }
            teardownLocked()
            reconnectAttempt = 0
            connectLocked()
        }
    }

    // MARK: - Connection (all on `queue`)

    private func connectLocked() {
        generation += 1
        let generation = self.generation
        _state = .connecting
        _clientConnected = false
        attached.removeAll()
        channel = SecureChannel(secret: pairing.secret, role: .host)

        var components = URLComponents(url: pairing.relay, resolvingAgainstBaseURL: false)!
        var path = components.path
        if path.hasSuffix("/") { path.removeLast() }
        components.path = path + "/v1/room/\(pairing.roomId)"
        components.queryItems = [URLQueryItem(name: "role", value: "host")]

        let socket = urlSession.webSocketTask(with: components.url!)
        self.socket = socket
        socket.resume()
        receiveNext(socket: socket, generation: generation)
    }

    private func receiveNext(socket: URLSessionWebSocketTask, generation: Int) {
        socket.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard generation == self.generation else { return }
                switch result {
                case .success(let message):
                    self.handle(message: message)
                    self.receiveNext(socket: socket, generation: generation)
                case .failure:
                    self.scheduleReconnectLocked()
                }
            }
        }
    }

    private func socketOpenedLocked(_ socket: URLSessionWebSocketTask) {
        guard socket === self.socket else { return }
        _state = .connected
        reconnectAttempt = 0
        sendControlLocked(.hello(
            who: .host, connEpoch: UInt32.random(in: .min ... .max), ver: 1
        ))
        sendControlLocked(.sessions(list: sessions.list()))
    }

    private func teardownLocked() {
        generation += 1
        reconnectWork?.cancel()
        reconnectWork = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        channel = nil
        _clientConnected = false
        attached.removeAll()
    }

    private func scheduleReconnectLocked() {
        teardownLocked()
        guard started else { return }
        _state = .connecting
        reconnectAttempt += 1
        let delay = min(0.5 * pow(2, Double(reconnectAttempt - 1)), 15)
            * Double.random(in: 0.8 ... 1.2)
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.started else { return }
            self.connectLocked()
        }
        reconnectWork = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - Receive (on `queue`)

    private func handle(message: URLSessionWebSocketTask.Message) {
        guard case .data(let data) = message else { return } // text frames are ignored

        let frame: Frame
        do {
            guard var channel else { return }
            let plaintext = try channel.open(data)
            self.channel = channel
            frame = try Frame.decode(plaintext)
        } catch SecureChannel.ChannelError.staleSequence {
            // The relay replaces the client connection in place, so the peer's
            // seq can restart at 1 while our channel persists. A hello bearing
            // a new connEpoch announces that fresh connection (spec §3);
            // anything else non-increasing is a replay and is dropped.
            if let hello = acceptFreshClientHello(in: data) {
                handle(control: hello)
            }
            return
        } catch {
            // Decryption failure → close, retry from fresh connection (spec §3).
            scheduleReconnectLocked()
            return
        }

        switch frame.type {
        case .ctl:
            guard let control = try? frame.controlMessage() else {
                sendControlLocked(.err(msg: "malformed ctl payload"))
                return
            }
            handle(control: control)
        case .stdin:
            sessions.write(id: Int(frame.sessionId), data: frame.payload)
        case .resize:
            guard let size = try? frame.resizeSize() else { return }
            sessions.resize(id: Int(frame.sessionId), cols: size.cols, rows: size.rows)
        case .stdout, .replay:
            break // host→client only; ignore if mirrored back
        }
    }

    private func handle(control message: ControlMessage) {
        switch message {
        case .hello(let who, let connEpoch, _):
            guard who == .client else { return }
            // Fresh client connection: attach state starts empty (spec §3).
            clientConnEpoch = connEpoch
            _clientConnected = true
            attached.removeAll()
            sendControlLocked(.sessions(list: sessions.list()))
        case .create(let cwd, let cols, let rows):
            do {
                let id = try sessions.create(cwd: cwd, cols: cols, rows: rows)
                // `sessions` ctl is emitted by the SessionManager event.
                sendControlLocked(.created(id: id))
            } catch {
                sendControlLocked(.err(msg: "create failed: \(error)"))
            }
        case .close(let id):
            if !sessions.close(id: id) {
                sendControlLocked(.err(msg: "no such session \(id)"))
            }
        case .attach(let id):
            guard let snapshot = sessions.replaySnapshot(id: id) else {
                sendControlLocked(.err(msg: "no such session \(id)"))
                return
            }
            attached[id] = snapshot.coversUpTo
            sendLocked(frame: .replay(sessionId: UInt32(id), data: snapshot.data))
        case .detach(let id):
            attached.removeValue(forKey: id)
        case .sessions, .created, .title, .exit:
            break // host→client only; ignore if mirrored back
        case .err(let msg):
            FileHandle.standardError.write(Data("client error: \(msg)\n".utf8))
        }
    }

    /// If `data` decrypts to a client `hello` with a connEpoch we have not
    /// seen, resets the channel's receive counter to its seq and returns it.
    private func acceptFreshClientHello(in data: Data) -> ControlMessage? {
        guard var channel,
              let (seq, plaintext) = try? channel.openIgnoringSequence(data),
              let frame = try? Frame.decode(plaintext), frame.type == .ctl,
              let control = try? frame.controlMessage(),
              case .hello(let who, let connEpoch, _) = control,
              who == .client, connEpoch != clientConnEpoch
        else { return nil }
        channel.resetReceiveSequence(to: seq)
        self.channel = channel
        return control
    }

    // MARK: - Session events (on `queue`)

    private func handle(sessionEvent event: SessionEvent) {
        switch event {
        case .sessionsChanged(let list):
            sendControlLocked(.sessions(list: list))
        case .output(let id, let data, let offset):
            guard let replayedThrough = attached[id] else { return }
            let end = offset + UInt64(data.count)
            guard end > replayedThrough else { return } // fully covered by replay
            let payload: Data
            if offset >= replayedThrough {
                payload = data
            } else {
                payload = data.suffix(Int(end - replayedThrough))
            }
            sendLocked(frame: .stdout(sessionId: UInt32(id), data: payload))
        case .title(let id, let title):
            sendControlLocked(.title(id: id, title: title))
        case .exit(let id, let code):
            sendControlLocked(.exit(id: id, code: code))
        }
    }

    // MARK: - Send (on `queue`)

    private func sendControlLocked(_ message: ControlMessage) {
        guard let frame = try? Frame.control(message) else { return }
        sendLocked(frame: frame)
    }

    private func sendLocked(frame: Frame) {
        guard let socket, socket.state == .running, channel != nil else { return }
        guard let sealed = try? channel!.seal(frame) else { return }
        let generation = self.generation
        socket.send(.data(sealed)) { [weak self] error in
            guard error != nil, let self else { return }
            self.queue.async {
                guard generation == self.generation else { return }
                self.scheduleReconnectLocked()
            }
        }
    }
}

// MARK: - URLSessionWebSocketDelegate

extension RelayHostClient: URLSessionWebSocketDelegate {
    public func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        queue.async { [weak self] in
            self?.socketOpenedLocked(webSocketTask)
        }
    }
}
