import Combine
import Foundation
import PedalsKit

/// Client end of the relay connection: WSS to `relay/v1/room/:roomId?role=client`,
/// E2EE via PedalsKit `SecureChannel`, reconnect with exponential backoff, and
/// Combine publishing of state + decrypted host events.
@MainActor
final class ConnectionController: NSObject {
    enum State: Equatable {
        case unpaired
        case connecting
        case connected
        case reconnecting(attempt: Int)
    }

    enum HostEvent {
        case sessions([SessionInfo])
        case created(id: Int)
        case title(id: Int, title: String)
        case exit(id: Int, code: Int)
        case replay(sessionId: UInt32, data: Data)
        case stdout(sessionId: UInt32, data: Data)
        case error(message: String)
    }

    @Published private(set) var pairing: PairingInfo?
    @Published private(set) var state: State = .unpaired
    /// True once the host's `hello` was received on the current connection.
    @Published private(set) var hostOnline = false
    /// Latest WebSocket ping RTT to the relay, seconds.
    @Published private(set) var roundTripTime: TimeInterval?

    let events = PassthroughSubject<HostEvent, Never>()

    private let pairingStore: PairingStore
    private lazy var urlSession = URLSession(
        configuration: .default, delegate: self, delegateQueue: nil
    )
    private var socket: URLSessionWebSocketTask?
    private var channel: SecureChannel?
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    /// Bumped on every (re)connect and teardown so callbacks from stale
    /// connections are ignored.
    private var generation = 0
    /// Sessions the client wants stdout for; re-sent as `attach` after reconnect.
    private var attachedSessionIds: Set<Int> = []
    /// connEpoch of the host connection we last accepted a hello from.
    private var hostConnEpoch: UInt32?

    init(pairingStore: PairingStore) {
        self.pairingStore = pairingStore
        super.init()
        pairing = pairingStore.load()
    }

    // MARK: - Pairing

    func pair(with info: PairingInfo) {
        pairingStore.save(info)
        pairing = info
        attachedSessionIds.removeAll()
        reconnectAttempt = 0
        start()
    }

    func unpair() {
        pairingStore.clear()
        pairing = nil
        teardownConnection()
        attachedSessionIds.removeAll()
        state = .unpaired
        events.send(.sessions([]))
    }

    // MARK: - Connection lifecycle

    func start() {
        guard let pairing else {
            state = .unpaired
            return
        }
        teardownConnection()
        connect(pairing)
    }

    private func connect(_ pairing: PairingInfo) {
        self.generation += 1
        let generation = self.generation

        guard let url = Self.roomURL(pairing: pairing) else {
            state = .unpaired
            events.send(.error(message: "Invalid relay URL"))
            return
        }

        state = reconnectAttempt == 0 ? .connecting : .reconnecting(attempt: reconnectAttempt)
        hostOnline = false
        roundTripTime = nil
        channel = SecureChannel(secret: pairing.secret, role: .client)

        let socket = urlSession.webSocketTask(with: url)
        self.socket = socket
        socket.resume()

        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await socket.receive()
                    guard let self else { return }
                    self.handle(message: message, generation: generation)
                } catch {
                    self?.handleConnectionFailure(generation: generation)
                    return
                }
            }
        }
    }

    static func roomURL(pairing: PairingInfo) -> URL? {
        guard var components = URLComponents(
            url: pairing.relay, resolvingAgainstBaseURL: false
        ) else { return nil }
        var path = components.path
        if path.hasSuffix("/") { path.removeLast() }
        components.path = path + "/v1/room/\(pairing.roomId)"
        components.queryItems = [URLQueryItem(name: "role", value: "client")]
        return components.url
    }

    private func handleSocketOpened(_ socket: URLSessionWebSocketTask) {
        guard socket === self.socket else { return }
        state = .connected
        reconnectAttempt = 0
        send(.hello(who: .client, connEpoch: UInt32.random(in: .min ... .max), ver: 1))
        for id in attachedSessionIds.sorted() {
            send(.attach(id: id))
        }
        startPingLoop(socket: socket, generation: generation)
    }

    private func handleConnectionFailure(generation: Int) {
        guard generation == self.generation else { return }
        teardownConnection()
        guard let pairing else {
            state = .unpaired
            return
        }
        hostOnline = false
        roundTripTime = nil
        reconnectAttempt += 1
        state = .reconnecting(attempt: reconnectAttempt)
        let delay = min(0.5 * pow(2, Double(reconnectAttempt - 1)), 15)
            * Double.random(in: 0.8 ... 1.2)
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.connect(pairing)
        }
    }

    private func teardownConnection() {
        generation += 1
        receiveTask?.cancel()
        receiveTask = nil
        pingTask?.cancel()
        pingTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        channel = nil
    }

    // MARK: - Ping / RTT

    private func startPingLoop(socket: URLSessionWebSocketTask, generation: Int) {
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, generation == self.generation else { return }
                let start = ContinuousClock.now
                socket.sendPing { [weak self] error in
                    guard error == nil else { return }
                    let rtt = start.duration(to: .now)
                    Task { @MainActor [weak self] in
                        guard let self, generation == self.generation else { return }
                        self.roundTripTime = Double(rtt.components.seconds)
                            + Double(rtt.components.attoseconds) * 1e-18
                    }
                }
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    // MARK: - Receive

    private func handle(message: URLSessionWebSocketTask.Message, generation: Int) {
        guard generation == self.generation else { return }
        guard case let .data(data) = message else { return } // text frames are ignored

        let frame: Frame
        do {
            guard let opened = try channel?.open(data) else { return }
            frame = try Frame.decode(opened)
        } catch SecureChannel.ChannelError.staleSequence {
            // The host can reconnect to the relay while our connection
            // persists, restarting its seq at 1. A hello bearing a new
            // connEpoch announces that fresh connection (spec §3); anything
            // else non-increasing is a replay and is dropped.
            if let hello = acceptFreshHostHello(in: data) {
                handle(control: hello)
            }
            return
        } catch {
            // Decryption/decode failure: close and retry from a fresh connection.
            handleConnectionFailure(generation: generation)
            return
        }

        // Any frame that decrypts with the host's key proves the host is online,
        // even when we joined after its hello (the relay does not queue it).
        hostOnline = true

        switch frame.type {
        case .ctl:
            guard let message = try? frame.controlMessage() else { return }
            handle(control: message)
        case .stdout:
            events.send(.stdout(sessionId: frame.sessionId, data: frame.payload))
        case .replay:
            events.send(.replay(sessionId: frame.sessionId, data: frame.payload))
        case .stdin, .resize:
            break // client→host only; ignore if mirrored back
        }
    }

    private func handle(control message: ControlMessage) {
        switch message {
        case let .hello(who, connEpoch, _):
            guard who == .host else { break }
            hostOnline = true
            hostConnEpoch = connEpoch
        case let .sessions(list):
            attachedSessionIds.formIntersection(list.map(\.id))
            events.send(.sessions(list))
        case let .created(id):
            events.send(.created(id: id))
        case let .title(id, title):
            events.send(.title(id: id, title: title))
        case let .exit(id, code):
            events.send(.exit(id: id, code: code))
        case let .err(msg):
            events.send(.error(message: msg))
        case .create, .close, .attach, .detach:
            break
        }
    }

    /// If `data` decrypts to a host `hello` with a connEpoch we have not
    /// seen, resets the channel's receive counter to its seq and returns it.
    private func acceptFreshHostHello(in data: Data) -> ControlMessage? {
        guard var channel,
              let (seq, plaintext) = try? channel.openIgnoringSequence(data),
              let frame = try? Frame.decode(plaintext), frame.type == .ctl,
              let control = try? frame.controlMessage(),
              case .hello(let who, let connEpoch, _) = control,
              who == .host, connEpoch != hostConnEpoch
        else { return nil }
        channel.resetReceiveSequence(to: seq)
        self.channel = channel
        return control
    }

    // MARK: - Send

    func createSession(cols: Int, rows: Int, cwd: String? = nil) {
        send(.create(cwd: cwd, cols: cols, rows: rows))
    }

    func closeSession(id: Int) {
        send(.close(id: id))
    }

    func attach(id: Int) {
        guard attachedSessionIds.insert(id).inserted else { return }
        send(.attach(id: id))
    }

    func detach(id: Int) {
        guard attachedSessionIds.remove(id) != nil else { return }
        send(.detach(id: id))
    }

    func sendStdin(sessionId: UInt32, data: Data) {
        send(frame: .stdin(sessionId: sessionId, data: data))
    }

    func sendResize(sessionId: UInt32, cols: UInt16, rows: UInt16) {
        send(frame: .resize(sessionId: sessionId, cols: cols, rows: rows))
    }

    private func send(_ message: ControlMessage) {
        guard let frame = try? Frame.control(message) else { return }
        send(frame: frame)
    }

    private func send(frame: Frame) {
        guard let socket else { return }
        let generation = self.generation
        guard let sealed = try? channel?.seal(frame) else { return }
        socket.send(.data(sealed)) { [weak self] error in
            guard error != nil else { return }
            Task { @MainActor [weak self] in
                self?.handleConnectionFailure(generation: generation)
            }
        }
    }
}

// MARK: - URLSessionWebSocketDelegate

extension ConnectionController: URLSessionWebSocketDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol proto: String?
    ) {
        Task { @MainActor [weak self] in
            self?.handleSocketOpened(webSocketTask)
        }
    }
}
