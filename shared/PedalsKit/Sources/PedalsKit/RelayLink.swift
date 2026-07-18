import Foundation

/// One encrypted, authenticated relay WebSocket (PROTOCOL.md section 1/3).
///
/// The v2 relay derives the socket role from the bearer credential and the
/// persisted client-computer binding; a caller can no longer claim a role in
/// the URL. `role` here only selects the E2EE direction keys and hello payload.
///
/// Callbacks are delivered on `callbackQueue`; all public methods are
/// thread-safe.
public final class RelayLink: NSObject, @unchecked Sendable {
    public enum Channel: Equatable, Sendable {
        case control
        case session(sid: UInt32)
    }

    public enum State: Equatable, Sendable {
        case idle
        /// attempt 0 = first connect; >0 = reconnect (with backoff).
        case connecting(attempt: Int)
        case connected
    }

    private let computer: ComputerBinding
    private let authorization: String
    private let role: PeerRole
    /// Stable authenticated installation/computer identifier. It is carried
    /// inside E2EE hello so a reconnect replaces that principal's old tag.
    private let principalID: String
    private let channelKind: Channel
    /// host role only: machine name announced in `hello`.
    private let hostName: String?

    private let queue = DispatchQueue(label: "air.build.pedals.relaylink")
    private let callbackQueue: DispatchQueue

    /// Every decrypted frame, including the peer's `hello` ctl.
    public var onFrame: (@Sendable (Frame) -> Void)?
    public var onState: (@Sendable (State) -> Void)?
    /// Relay presence notification (§1): whether the peer role currently has a
    /// live socket on this channel. Delivered on connect and on peer changes.
    public var onPeerPresence: (@Sendable (Bool) -> Void)?
    /// WebSocket ping RTT samples (seconds), roughly every 10 s while connected.
    public var onRoundTrip: (@Sendable (TimeInterval) -> Void)?

    private var urlSession: URLSession!
    private var socket: URLSessionWebSocketTask?
    /// Long-term-key channel used exclusively for fresh-nonce hello frames.
    private var bootstrapChannel: SecureChannel?
    /// Connection-bound peer channels keyed by their public 16-byte routing tag.
    /// A host socket can serve several clients, so it keeps one cipher per peer.
    private var peerChannels: [Data: SecureChannel] = [:]
    private var peerOrder: [Data] = []
    /// A replayable long-term-key hello creates only a pending candidate. The
    /// candidate becomes active after a connection-bound ready proof arrives.
    private var pendingPeerChannels: [Data: SecureChannel] = [:]
    private var pendingPeerHellos: [Data: Frame] = [:]
    private var pendingPeerPrincipals: [Data: String] = [:]
    private var pendingTagByPrincipal: [String: Data] = [:]
    private var pendingPeerOrder: [Data] = []
    private var peerPrincipalByTag: [Data: String] = [:]
    private var peerTagByPrincipal: [String: Data] = [:]
    private var localNonce = Data()
    /// Only client commands wait for the host handshake. Host output remains
    /// intentionally unqueued when no client is present.
    private var pendingClientFrames: [Frame] = []
    private var started = false
    private var reconnectAttempt = 0
    private var reconnectWork: DispatchWorkItem?
    private var pingTimer: DispatchSourceTimer?
    /// Bumped on every (re)connect and teardown; stale callbacks are ignored.
    private var generation = 0
    private var _state: State = .idle

    private static let routingTagByteCount = 16
    private static let bootstrapTag = Data(repeating: 0, count: routingTagByteCount)
    /// The Worker rejects peer E2EE wires above 1 MiB. Host receives add the
    /// authenticated source envelope outside that limit.
    private static let maximumPeerWireByteCount = 1024 * 1024
    private static let maximumPeerChannels = 64
    private static let maximumPendingPeerChannels = 128
    private static let maximumPendingClientFrames = 64

    public var state: State { queue.sync { _state } }

    public init(
        computer: ComputerBinding,
        authorization: String,
        role: PeerRole,
        principalID: String,
        channel: Channel,
        hostName: String? = nil,
        callbackQueue: DispatchQueue = .main
    ) {
        self.computer = computer
        self.authorization = authorization
        self.role = role
        precondition(RelaySourceEnvelope.isCanonicalPrincipal(principalID.lowercased()))
        self.principalID = principalID.lowercased()
        self.channelKind = channel
        self.hostName = hostName
        self.callbackQueue = callbackQueue
        super.init()
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = false
        // Bounds the WebSocket handshake: on a black-holed network the default
        // 60 s would stall each reconnect attempt for a minute.
        configuration.timeoutIntervalForRequest = 15
        urlSession = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    // MARK: - Lifecycle

    public func start() {
        queue.async { [self] in
            guard !started else { return }
            started = true
            reconnectAttempt = 0
            connectLocked()
        }
    }

    public func stop() {
        queue.async { [self] in
            started = false
            teardownLocked()
            setStateLocked(.idle)
            // URLSession strongly retains its delegate (self) until invalidated;
            // without this the RelayLink + URLSession leak after the last caller
            // drops us (stop is terminal — reconnects go through `kick`, not
            // stop, so the session is never reused afterward).
            urlSession.finishTasksAndInvalidate()
        }
    }

    /// Drops the current socket (if any) and reconnects immediately.
    /// No-op unless started. Use on foregrounding / connectivity changes.
    public func kick() {
        queue.async { [self] in
            guard started else { return }
            teardownLocked()
            reconnectAttempt = 0
            connectLocked()
        }
    }

    public func send(_ frame: Frame) {
        queue.async { [self] in
            sendLocked(frame: frame)
        }
    }

    public func send(_ message: ControlMessage) {
        queue.async { [self] in
            guard let frame = try? Frame.control(message) else { return }
            sendLocked(frame: frame)
        }
    }

    /// Sends authenticated relay metadata outside the E2EE frame stream.
    /// Only the daemon uses this on its control link to publish aggregate,
    /// non-terminal state such as the number of alive TTYs.
    public func sendRelayText(_ text: String) {
        queue.async { [self] in
            guard let socket, case .connected = _state else { return }
            let generation = self.generation
            socket.send(.string(text)) { [weak self] error in
                guard error != nil, let self else { return }
                self.queue.async {
                    guard generation == self.generation else { return }
                    self.scheduleReconnectLocked()
                }
            }
        }
    }

    // MARK: - Connection (all on `queue`)

    private func relayURL() -> URL? {
        guard var components = URLComponents(
            url: computer.relayURL, resolvingAgainstBaseURL: false
        ) else { return nil }
        var path = components.path
        if path.hasSuffix("/") { path.removeLast() }
        components.path = path + "/v2/relay/\(computer.computerID)"
        var query: [URLQueryItem] = []
        switch channelKind {
        case .control:
            query.append(URLQueryItem(name: "channel", value: "control"))
        case .session(let sid):
            query.append(URLQueryItem(name: "channel", value: "session"))
            query.append(URLQueryItem(name: "sid", value: String(sid)))
        }
        components.queryItems = query
        return components.url
    }

    private var keyChannel: KeyDerivation.Channel {
        switch channelKind {
        case .control: .control
        case .session(let sid): .session(sid)
        }
    }

    private func connectLocked() {
        generation += 1
        let generation = self.generation
        setStateLocked(.connecting(attempt: reconnectAttempt))
        localNonce = SecureRandom.data(count: KeyDerivation.ConnectionBinding.nonceByteCount)
        bootstrapChannel = SecureChannel(
            secret: computer.secret, role: role, channel: keyChannel
        )
        peerChannels.removeAll(keepingCapacity: true)
        peerOrder.removeAll(keepingCapacity: true)
        peerPrincipalByTag.removeAll(keepingCapacity: true)
        peerTagByPrincipal.removeAll(keepingCapacity: true)
        pendingPeerChannels.removeAll(keepingCapacity: true)
        pendingPeerHellos.removeAll(keepingCapacity: true)
        pendingPeerPrincipals.removeAll(keepingCapacity: true)
        pendingTagByPrincipal.removeAll(keepingCapacity: true)
        pendingPeerOrder.removeAll(keepingCapacity: true)
        pendingClientFrames.removeAll(keepingCapacity: true)

        guard let url = relayURL() else { return }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(authorization)", forHTTPHeaderField: "Authorization")
        let socket = urlSession.webSocketTask(with: request)
        // URLSession defaults to exactly 1 MiB. Client-to-host messages gain a
        // 33-byte relay-authenticated source header, so the host must opt into
        // the protocol's actual maximum receive size.
        socket.maximumMessageSize = Self.maximumPeerWireByteCount
            + (role == .host ? RelaySourceEnvelope.headerByteCount : 0)
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
                    self.handleLocked(message: message)
                    self.receiveNext(socket: socket, generation: generation)
                case .failure:
                    self.scheduleReconnectLocked()
                }
            }
        }
    }

    fileprivate func socketOpened(_ socket: URLSessionWebSocketTask) {
        queue.async { [self] in
            guard socket === self.socket else { return }
            reconnectAttempt = 0
            setStateLocked(.connected)
            sendHelloLocked()
            startPingLocked(socket: socket, generation: generation)
        }
    }

    private func sendHelloLocked() {
        guard var bootstrapChannel,
              let frame = try? Frame.control(.hello(
                  who: role,
                  principal: principalID,
                  connEpoch: bootstrapChannel.connEpoch,
                  nonce: localNonce,
                  ver: 2,
                  host: hostName
              ))
        else { return }
        guard let sealed = try? bootstrapChannel.seal(
            frame, context: Self.bootstrapTag
        ) else { return }
        self.bootstrapChannel = bootstrapChannel
        sendWireLocked(tag: Self.bootstrapTag, sealed: sealed)
    }

    private func teardownLocked() {
        generation += 1
        reconnectWork?.cancel()
        reconnectWork = nil
        pingTimer?.cancel()
        pingTimer = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        bootstrapChannel = nil
        peerChannels.removeAll()
        peerOrder.removeAll()
        peerPrincipalByTag.removeAll()
        peerTagByPrincipal.removeAll()
        pendingPeerChannels.removeAll()
        pendingPeerHellos.removeAll()
        pendingPeerPrincipals.removeAll()
        pendingTagByPrincipal.removeAll()
        pendingPeerOrder.removeAll()
        localNonce.removeAll(keepingCapacity: false)
        pendingClientFrames.removeAll()
    }

    private func scheduleReconnectLocked() {
        teardownLocked()
        guard started else { return }
        reconnectAttempt += 1
        setStateLocked(.connecting(attempt: reconnectAttempt))
        let delay = min(0.5 * pow(2, Double(reconnectAttempt - 1)), 15)
            * Double.random(in: 0.8 ... 1.2)
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.started else { return }
            self.connectLocked()
        }
        reconnectWork = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func startPingLocked(socket: URLSessionWebSocketTask, generation: Int) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { [weak self] in
            guard let self, generation == self.generation else { return }
            let start = DispatchTime.now()
            socket.sendPing { [weak self] error in
                guard let self else { return }
                self.queue.async {
                    guard generation == self.generation else { return }
                    if error != nil {
                        // A dead connection often only surfaces on write; the
                        // ping doubles as a liveness probe.
                        self.scheduleReconnectLocked()
                    } else if let onRoundTrip = self.onRoundTrip {
                        let elapsed = Double(
                            DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
                        ) / 1e9
                        self.callbackQueue.async { onRoundTrip(elapsed) }
                    }
                }
            }
        }
        timer.resume()
        pingTimer?.cancel()
        pingTimer = timer
    }

    // MARK: - Receive (on `queue`)

    /// Plaintext relay→peer metadata (§1). Only `presence` exists today.
    private struct RelayNotice: Decodable {
        let type: String
        let online: Bool?
    }

    private func handleLocked(message: URLSessionWebSocketTask.Message) {
        if case .string(let text) = message {
            // Text frames are relay link metadata, never peer payload.
            guard let notice = try? JSONDecoder().decode(
                RelayNotice.self, from: Data(text.utf8)
            ), notice.type == "presence", let online = notice.online
            else { return }
            if let onPeerPresence {
                callbackQueue.async { onPeerPresence(online) }
            }
            return
        }
        guard case .data(let data) = message else { return }
        let sourcePrincipal: String?
        let wire: Data
        switch role {
        case .host:
            // A host never guesses between old and new formats. Every inbound
            // client binary message must carry the v2 source envelope created
            // by the authenticated Durable Object socket attachment.
            guard let envelope = RelaySourceEnvelope(data: data) else { return }
            sourcePrincipal = envelope.principal
            wire = envelope.wire
        case .client:
            sourcePrincipal = nil
            wire = data
        }
        guard wire.count > Self.routingTagByteCount else { return }
        let tag = Data(wire.prefix(Self.routingTagByteCount))
        let sealed = Data(wire.dropFirst(Self.routingTagByteCount))
        if tag == Self.bootstrapTag {
            handleBootstrapLocked(sealed: sealed, sourcePrincipal: sourcePrincipal)
        } else {
            handlePeerLocked(
                tag: tag, sealed: sealed, sourcePrincipal: sourcePrincipal
            )
        }
    }

    private func handleBootstrapLocked(sealed: Data, sourcePrincipal: String?) {
        do {
            guard var bootstrapChannel else { return }
            let opened = try bootstrapChannel.openWithSequence(
                sealed, context: Self.bootstrapTag
            )
            let frame = try Frame.decode(opened.plaintext)
            guard frame.type == .ctl,
                  frame.sessionId == 0,
                  let message = try? frame.controlMessage(),
                  case let .hello(
                      who, peerPrincipal, connEpoch, peerNonce, ver, _
                  ) = message,
                  who != role,
                  ver == 2,
                  let authenticatedPrincipal = RelaySourceEnvelope
                    .authenticatedHelloPrincipal(
                        localRole: role,
                        envelopeSource: sourcePrincipal,
                        claimedPrincipal: peerPrincipal,
                        computerID: computer.computerID
                    ),
                  peerNonce.count == KeyDerivation.ConnectionBinding.nonceByteCount,
                  connEpoch == UInt32(truncatingIfNeeded: opened.sequence >> 32)
            else { return }

            // Commit replay state only after the encrypted hello agrees with
            // the outer authenticated source. A mismatched client must not
            // consume another principal's bootstrap sequence.
            self.bootstrapChannel = bootstrapChannel

            let binding: KeyDerivation.ConnectionBinding
            switch role {
            case .host:
                binding = .init(hostNonce: localNonce, clientNonce: peerNonce)
            case .client:
                binding = .init(hostNonce: peerNonce, clientNonce: localNonce)
            }
            let tag = binding.tag
            guard peerChannels[tag] == nil, pendingPeerChannels[tag] == nil else {
                return
            }

            if let priorPending = pendingTagByPrincipal[authenticatedPrincipal] {
                removePendingPeerLocked(tag: priorPending)
            }
            if pendingPeerOrder.count >= Self.maximumPendingPeerChannels,
               let oldest = pendingPeerOrder.first
            {
                removePendingPeerLocked(tag: oldest)
            }
            pendingPeerChannels[tag] = SecureChannel(
                secret: computer.secret,
                role: role,
                channel: keyChannel,
                connEpoch: bootstrapChannel.connEpoch,
                connection: binding
            )
            pendingPeerHellos[tag] = frame
            pendingPeerPrincipals[tag] = authenticatedPrincipal
            pendingTagByPrincipal[authenticatedPrincipal] = tag
            pendingPeerOrder.append(tag)

            // Either side may have attached second, after its peer's initial
            // hello was dropped. Respond once and then prove the derived key.
            sendHelloLocked()
            sendReadyLocked(tag: tag, echoNonce: peerNonce)
        } catch {
            // The relay is untrusted and host sockets aggregate many senders.
            // Bad/replayed bootstrap frames are isolated and dropped instead
            // of taking every legitimate peer offline.
            return
        }
    }

    private func handlePeerLocked(
        tag: Data, sealed: Data, sourcePrincipal: String?
    ) {
        do {
            if var channel = peerChannels[tag] {
                guard RelaySourceEnvelope.authorizesPeerFrame(
                    localRole: role,
                    envelopeSource: sourcePrincipal,
                    boundPrincipal: peerPrincipalByTag[tag]
                ) else { return }
                let plaintext = try channel.open(sealed, context: tag)
                peerChannels[tag] = channel
                let frame = try Frame.decode(plaintext)
                if frame.type == .ctl,
                   let message = try? frame.controlMessage()
                {
                    switch message {
                    case .hello, .ready:
                        return
                    default:
                        break
                    }
                }
                deliverLocked(frame)
                return
            }

            guard var pending = pendingPeerChannels[tag] else { return }
            guard RelaySourceEnvelope.authorizesPeerFrame(
                localRole: role,
                envelopeSource: sourcePrincipal,
                boundPrincipal: pendingPeerPrincipals[tag]
            ) else { return }
            let plaintext = try pending.open(sealed, context: tag)
            pendingPeerChannels[tag] = pending
            let frame = try Frame.decode(plaintext)
            guard frame.type == .ctl,
                  let message = try? frame.controlMessage(),
                  case let .ready(who, echoNonce) = message,
                  who != role,
                  echoNonce == localNonce
            else { return }
            promotePendingPeerLocked(tag: tag, channel: pending)
        } catch {
            // Unknown tags, stale counters, bad AEAD, and malformed frames are
            // per-sender failures. Drop them without reconnecting this socket.
            return
        }
    }

    private func deliverLocked(_ frame: Frame) {
        if let onFrame {
            callbackQueue.async { onFrame(frame) }
        }
    }

    private func sendReadyLocked(tag: Data, echoNonce: Data) {
        guard var channel = pendingPeerChannels[tag],
              let frame = try? Frame.control(
                  .ready(who: role, echoNonce: echoNonce)
              ),
              let sealed = try? channel.seal(frame, context: tag)
        else { return }
        pendingPeerChannels[tag] = channel
        sendWireLocked(tag: tag, sealed: sealed)
    }

    private func promotePendingPeerLocked(tag: Data, channel: SecureChannel) {
        guard let principal = pendingPeerPrincipals[tag],
              let hello = pendingPeerHellos[tag]
        else { return }
        removePendingPeerLocked(tag: tag)

        if role == .client {
            // A relay channel has one active host. Once a fresh proof arrives,
            // old host tags must stop receiving duplicated client commands.
            for oldTag in Array(peerChannels.keys) {
                removeActivePeerLocked(tag: oldTag)
            }
        } else if let oldTag = peerTagByPrincipal[principal], oldTag != tag {
            removeActivePeerLocked(tag: oldTag)
        }
        if peerOrder.count >= Self.maximumPeerChannels,
           let oldest = peerOrder.first
        {
            removeActivePeerLocked(tag: oldest)
        }
        peerChannels[tag] = channel
        peerPrincipalByTag[tag] = principal
        peerTagByPrincipal[principal] = tag
        peerOrder.append(tag)
        deliverLocked(hello)
        flushPendingClientFramesLocked()
    }

    private func removePendingPeerLocked(tag: Data) {
        if let principal = pendingPeerPrincipals.removeValue(forKey: tag),
           pendingTagByPrincipal[principal] == tag
        {
            pendingTagByPrincipal.removeValue(forKey: principal)
        }
        pendingPeerChannels.removeValue(forKey: tag)
        pendingPeerHellos.removeValue(forKey: tag)
        pendingPeerOrder.removeAll { $0 == tag }
    }

    private func removeActivePeerLocked(tag: Data) {
        if let principal = peerPrincipalByTag.removeValue(forKey: tag),
           peerTagByPrincipal[principal] == tag
        {
            peerTagByPrincipal.removeValue(forKey: principal)
        }
        peerChannels.removeValue(forKey: tag)
        peerOrder.removeAll { $0 == tag }
    }

    // MARK: - Send (on `queue`)

    private func sendLocked(frame: Frame) {
        guard socket != nil, case .connected = _state else { return }
        if peerChannels.isEmpty {
            if role == .client {
                if pendingClientFrames.count >= Self.maximumPendingClientFrames {
                    pendingClientFrames.removeFirst()
                }
                pendingClientFrames.append(frame)
            }
            return
        }
        for tag in Array(peerChannels.keys) {
            guard var channel = peerChannels[tag],
                  let sealed = try? channel.seal(frame, context: tag)
            else { continue }
            peerChannels[tag] = channel
            sendWireLocked(tag: tag, sealed: sealed)
        }
    }

    private func flushPendingClientFramesLocked() {
        guard role == .client, !peerChannels.isEmpty,
              !pendingClientFrames.isEmpty
        else { return }
        let frames = pendingClientFrames
        pendingClientFrames.removeAll(keepingCapacity: true)
        for frame in frames { sendLocked(frame: frame) }
    }

    private func sendWireLocked(tag: Data, sealed: Data) {
        guard let socket, case .connected = _state else { return }
        var wire = tag
        wire.append(sealed)
        let generation = self.generation
        socket.send(.data(wire)) { [weak self] error in
            guard error != nil, let self else { return }
            self.queue.async {
                guard generation == self.generation else { return }
                self.scheduleReconnectLocked()
            }
        }
    }

    private func setStateLocked(_ state: State) {
        guard state != _state else { return }
        _state = state
        if let onState {
            callbackQueue.async { onState(state) }
        }
    }
}

// MARK: - URLSessionWebSocketDelegate

extension RelayLink: URLSessionWebSocketDelegate {
    public func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        socketOpened(webSocketTask)
    }
}
