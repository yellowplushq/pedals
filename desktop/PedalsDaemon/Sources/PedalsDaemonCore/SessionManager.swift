import Darwin
import Foundation
import PedalsKit

/// Event emitted by `SessionManager`. Offsets are cumulative output byte counts
/// so a consumer can splice a replay snapshot and the live stream without
/// duplicating bytes (see `RelayHostClient`).
public enum SessionEvent: Sendable {
    /// The session list changed (create / close / exit / title).
    case sessionsChanged([SessionInfo])
    /// Raw PTY output. `offset` is the total number of bytes output before this chunk.
    case output(id: Int, data: Data, offset: UInt64)
    case title(id: Int, title: String)
    case exit(id: Int, code: Int)
}

/// Owns all PTY sessions (PROTOCOL.md §6): spawn, ring buffers, titles, teardown.
/// Thread-safe; events are delivered on an internal serial queue.
public final class SessionManager: @unchecked Sendable {
    public struct Options: Sendable {
        /// Shell binary. Default: `$SHELL`, fallback `/bin/zsh`.
        public var shell: String
        /// Arguments after the shell path. Default: interactive login shell.
        public var shellArguments: [String]
        public var extraEnvironment: [String: String]
        public var defaultCols: UInt16 = 120
        public var defaultRows: UInt16 = 40

        public init(
            shell: String? = nil,
            shellArguments: [String] = ["-il"],
            extraEnvironment: [String: String] = [:]
        ) {
            let env = ProcessInfo.processInfo.environment["SHELL"]
            self.shell = shell ?? (env?.isEmpty == false ? env! : "/bin/zsh")
            self.shellArguments = shellArguments
            self.extraEnvironment = extraEnvironment
        }
    }

    private final class Session {
        let id: Int
        let cwd: String
        let createdAt: Date
        let pty: PTYProcess
        var cols: UInt16
        var rows: UInt16
        var ring = RingBuffer()
        var oscParser = OSCTitleParser()
        var outputOffset: UInt64 = 0
        var title: String
        /// Once an OSC 0/2 title arrives it wins over the process-name fallback.
        var titleFromOSC = false
        var alive = true
        var exitCode: Int?
        let agentTracker = AgentStateTracker()
        var agentVerdict = AgentStateTracker.Verdict(agent: nil, state: .idle)
        var lastAgentEval = Date.distantPast

        init(id: Int, cwd: String, pty: PTYProcess, cols: UInt16, rows: UInt16, title: String) {
            self.id = id
            self.cwd = cwd
            self.createdAt = Date()
            self.pty = pty
            self.cols = cols
            self.rows = rows
            self.title = title
        }

        var info: SessionInfo {
            SessionInfo(
                id: id, title: title, cwd: cwd, rows: Int(rows), cols: Int(cols),
                createdAt: createdAt.timeIntervalSince1970, alive: alive,
                agent: agentVerdict.agent,
                agentState: agentVerdict.agent == nil
                    ? nil : agentVerdict.state.rawValue
            )
        }
    }

    /// Serial queue on which all state mutation and event delivery happens.
    private let queue = DispatchQueue(label: "app.yellowplus.pedals.sessions")
    private let options: Options
    private var sessions: [Int: Session] = [:]
    private var nextId = 1
    private var titleTimer: DispatchSourceTimer?

    /// Delivered on the manager's serial queue. Handlers may call back into the
    /// manager (its public API only dispatches async or reads on the same queue).
    public var onEvent: (@Sendable (SessionEvent) -> Void)? {
        get { queue.sync { _onEvent } }
        set { queue.sync { _onEvent = newValue } }
    }
    private var _onEvent: (@Sendable (SessionEvent) -> Void)?

    public init(options: Options = Options()) {
        self.options = options
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in self?.pollFallbackTitles() }
        timer.resume()
        titleTimer = timer
    }

    deinit {
        titleTimer?.cancel()
    }

    // MARK: - Public API

    @discardableResult
    public func create(cwd: String? = nil, cols: Int? = nil, rows: Int? = nil) throws -> Int {
        try queue.sync {
            let cols = UInt16(clamping: cols ?? Int(options.defaultCols))
            let rows = UInt16(clamping: rows ?? Int(options.defaultRows))
            let directory = Self.resolveCwd(cwd)
            let pty = try PTYProcess(
                shell: options.shell,
                arguments: options.shellArguments,
                cwd: directory,
                cols: max(cols, 2),
                rows: max(rows, 2),
                extraEnvironment: options.extraEnvironment,
                queue: queue
            )
            let id = nextId
            nextId += 1
            let shellName = (options.shell as NSString).lastPathComponent
            let session = Session(
                id: id, cwd: directory, pty: pty, cols: max(cols, 2), rows: max(rows, 2),
                title: "\(shellName) — \(Self.abbreviate(path: directory))"
            )
            sessions[id] = session

            pty.onOutput = { [weak self] data in
                self?.handleOutput(id: id, data: data)
            }
            pty.onExit = { [weak self] code in
                self?.handleExit(id: id, code: code)
            }

            emitSessionsChangedLocked()
            return id
        }
    }

    /// Closes (kills) a session and removes it from the list.
    @discardableResult
    public func close(id: Int) -> Bool {
        queue.sync {
            guard let session = sessions.removeValue(forKey: id) else { return false }
            if session.alive { session.pty.terminate() }
            emitSessionsChangedLocked()
            return true
        }
    }

    public func write(id: Int, data: Data) {
        queue.async { [self] in
            guard let session = sessions[id], session.alive else { return }
            session.pty.write(data)
        }
    }

    public func resize(id: Int, cols: UInt16, rows: UInt16) {
        queue.async { [self] in
            guard let session = sessions[id], session.alive,
                  cols > 0, rows > 0,
                  session.cols != cols || session.rows != rows
            else { return }
            session.cols = cols
            session.rows = rows
            session.pty.resize(cols: cols, rows: rows)
            session.agentTracker.noteResize(cols: Int(cols), rows: Int(rows))
            emitSessionsChangedLocked()
        }
    }

    public func list() -> [SessionInfo] {
        queue.sync { sessions.values.sorted { $0.id < $1.id }.map(\.info) }
    }

    /// Ring-buffer snapshot + the output offset it covers, for replay-on-attach.
    public func replaySnapshot(id: Int) -> (data: Data, coversUpTo: UInt64)? {
        queue.sync {
            guard let session = sessions[id] else { return nil }
            return (session.ring.snapshot(), session.outputOffset)
        }
    }

    public func closeAll() {
        queue.sync {
            for session in sessions.values where session.alive {
                session.pty.terminate()
            }
            sessions.removeAll()
            emitSessionsChangedLocked()
        }
    }

    // MARK: - PTY callbacks (on `queue`)

    private func handleOutput(id: Int, data: Data) {
        guard let session = sessions[id] else { return }
        let offset = session.outputOffset
        session.ring.append(data)
        session.outputOffset += UInt64(data.count)
        _onEvent?(.output(id: id, data: data, offset: offset))

        if let title = session.oscParser.consume(data).last {
            session.titleFromOSC = true
            session.agentTracker.noteTitle(title)
            setTitleLocked(session: session, title: title)
        }

        session.agentTracker.noteOutput(data)
        // Screen-rule evaluation costs an ANSI strip of the tail buffer;
        // throttle it — the 2 s poll handles decay to idle regardless.
        if Date().timeIntervalSince(session.lastAgentEval) > 0.25 {
            reevaluateAgentLocked(session: session)
        }
    }

    private func reevaluateAgentLocked(session: Session) {
        session.lastAgentEval = Date()
        let verdict = session.agentTracker.evaluate()
        guard verdict != session.agentVerdict else { return }
        session.agentVerdict = verdict
        emitSessionsChangedLocked()
    }

    private func handleExit(id: Int, code: Int32) {
        guard let session = sessions[id] else { return }
        session.alive = false
        session.exitCode = Int(code)
        _onEvent?(.exit(id: id, code: Int(code)))
        emitSessionsChangedLocked()
    }

    // MARK: - Titles

    private func pollFallbackTitles() {
        for session in sessions.values where session.alive {
            let procs = session.pty.foregroundProcesses()
            session.agentTracker.noteForegroundProcesses(procs)
            reevaluateAgentLocked(session: session)

            // Title fallback: prefer a foreground process that isn't the shell
            // (the agent/command the user is running), else the shell itself.
            guard !session.titleFromOSC else { continue }
            let shellName = (options.shell as NSString).lastPathComponent
            let names = procs.map(\.comm)
            guard let name = names.first(where: { $0 != shellName }) ?? names.first
            else { continue }
            setTitleLocked(
                session: session,
                title: "\(name) — \(Self.abbreviate(path: session.cwd))"
            )
        }
    }

    private func setTitleLocked(session: Session, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != session.title else { return }
        session.title = trimmed
        _onEvent?(.title(id: session.id, title: trimmed))
        emitSessionsChangedLocked()
    }

    private func emitSessionsChangedLocked() {
        _onEvent?(.sessionsChanged(sessions.values.sorted { $0.id < $1.id }.map(\.info)))
    }

    // MARK: - Helpers

    private static func resolveCwd(_ cwd: String?) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard let cwd, !cwd.isEmpty else { return home }
        let expanded = (cwd as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return home }
        return expanded
    }

    private static func abbreviate(path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}
