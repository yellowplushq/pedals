import Foundation

/// Peer role, as carried in `hello.who` and the relay `role` query parameter.
public enum PeerRole: String, Codable, Sendable {
    case host
    case client
}

/// One entry of the `sessions` list (PROTOCOL.md §4).
public struct SessionInfo: Codable, Equatable, Sendable {
    public var id: Int
    public var title: String
    public var cwd: String
    public var rows: Int
    public var cols: Int
    /// Unix epoch seconds.
    public var createdAt: Double
    public var alive: Bool
    /// Detected agent id ("claude-code", "codex", "oh-my-pi", …), nil when the
    /// session isn't running a known agent. Additive in protocol v1.
    public var agent: String?
    /// "idle" | "working" | "blocked" — only meaningful when `agent` != nil.
    public var agentState: String?

    public init(id: Int, title: String, cwd: String, rows: Int, cols: Int,
                createdAt: Double, alive: Bool,
                agent: String? = nil, agentState: String? = nil) {
        self.id = id
        self.title = title
        self.cwd = cwd
        self.rows = rows
        self.cols = cols
        self.createdAt = createdAt
        self.alive = alive
        self.agent = agent
        self.agentState = agentState
    }
}

/// ctl JSON messages (PROTOCOL.md §4). Wire form is `{"t":"<kind>", ...}`.
public enum ControlMessage: Equatable, Sendable {
    /// First frame after connect, from each side.
    case hello(who: PeerRole, connEpoch: UInt32, ver: Int)
    /// host→client: full session list on hello and on any change.
    case sessions(list: [SessionInfo])
    /// client→host: create a session. `cwd` nil ⇒ JSON null.
    case create(cwd: String?, cols: Int, rows: Int)
    /// host→client: reply to `create`.
    case created(id: Int)
    /// client→host: close a session.
    case close(id: Int)
    /// client→host: subscribe to a session's stdout (host sends replay then live stdout).
    case attach(id: Int)
    /// client→host: stop streaming a session.
    case detach(id: Int)
    /// host→client: session title changed.
    case title(id: Int, title: String)
    /// host→client: session process exited.
    case exit(id: Int, code: Int)
    /// either direction: non-fatal error report.
    case err(msg: String)
}

extension ControlMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case t, who, connEpoch, ver, list, cwd, cols, rows, id, title, code, msg
    }

    private var kind: String {
        switch self {
        case .hello: "hello"
        case .sessions: "sessions"
        case .create: "create"
        case .created: "created"
        case .close: "close"
        case .attach: "attach"
        case .detach: "detach"
        case .title: "title"
        case .exit: "exit"
        case .err: "err"
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .t)
        switch self {
        case let .hello(who, connEpoch, ver):
            try container.encode(who, forKey: .who)
            try container.encode(connEpoch, forKey: .connEpoch)
            try container.encode(ver, forKey: .ver)
        case let .sessions(list):
            try container.encode(list, forKey: .list)
        case let .create(cwd, cols, rows):
            try container.encode(cwd, forKey: .cwd) // nil encodes as JSON null per spec
            try container.encode(cols, forKey: .cols)
            try container.encode(rows, forKey: .rows)
        case let .created(id), let .close(id), let .attach(id), let .detach(id):
            try container.encode(id, forKey: .id)
        case let .title(id, title):
            try container.encode(id, forKey: .id)
            try container.encode(title, forKey: .title)
        case let .exit(id, code):
            try container.encode(id, forKey: .id)
            try container.encode(code, forKey: .code)
        case let .err(msg):
            try container.encode(msg, forKey: .msg)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .t)
        switch kind {
        case "hello":
            self = .hello(
                who: try container.decode(PeerRole.self, forKey: .who),
                connEpoch: try container.decode(UInt32.self, forKey: .connEpoch),
                ver: try container.decode(Int.self, forKey: .ver)
            )
        case "sessions":
            self = .sessions(list: try container.decode([SessionInfo].self, forKey: .list))
        case "create":
            self = .create(
                cwd: try container.decodeIfPresent(String.self, forKey: .cwd),
                cols: try container.decode(Int.self, forKey: .cols),
                rows: try container.decode(Int.self, forKey: .rows)
            )
        case "created":
            self = .created(id: try container.decode(Int.self, forKey: .id))
        case "close":
            self = .close(id: try container.decode(Int.self, forKey: .id))
        case "attach":
            self = .attach(id: try container.decode(Int.self, forKey: .id))
        case "detach":
            self = .detach(id: try container.decode(Int.self, forKey: .id))
        case "title":
            self = .title(
                id: try container.decode(Int.self, forKey: .id),
                title: try container.decode(String.self, forKey: .title)
            )
        case "exit":
            self = .exit(
                id: try container.decode(Int.self, forKey: .id),
                code: try container.decode(Int.self, forKey: .code)
            )
        case "err":
            self = .err(msg: try container.decode(String.self, forKey: .msg))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .t, in: container,
                debugDescription: "unknown ctl message kind \"\(kind)\""
            )
        }
    }

    // MARK: JSON helpers

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public init(jsonData: Data) throws {
        self = try JSONDecoder().decode(ControlMessage.self, from: jsonData)
    }
}
