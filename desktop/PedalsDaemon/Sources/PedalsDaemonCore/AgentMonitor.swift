import Darwin
import Foundation
import PedalsKit

/// One ancestor of the reporting hook process, as carried in the local-socket
/// `agent-event` request (PROTOCOL.md §7). Enough to locate the agent
/// process, its tty, and its terminal app.
public struct AgentLineageEntry: Decodable, Equatable, Sendable {
    public var pid: Int32
    /// Kernel `p_comm`, truncated to 16 bytes by the kernel.
    public var name: String
    /// Controlling terminal device path ("/dev/ttys003"), nil if none.
    public var tty: String?

    public init(pid: Int32, name: String, tty: String? = nil) {
        self.pid = pid
        self.name = name
        self.tty = tty
    }
}

/// One hook-reported agent event, decoded from the local control socket
/// (`{"cmd":"agent-event",...}`, PROTOCOL.md §7).
public struct AgentEvent: Sendable {
    public var agent: String
    /// Stable vocabulary: `session-start`, `prompt`, `ask`, `tool`, `busy`,
    /// `notify`, `compact`, `stop`, `session-end`.
    public var event: String
    public var agentSessionId: String
    public var cwd: String?
    public var prompt: String?
    public var message: String?
    public var action: String?
    /// `stop` only: the turn ended on an agent-side failure (API error).
    public var agentError: Bool?
    public var lineage: [AgentLineageEntry]

    public init(
        agent: String, event: String, agentSessionId: String, cwd: String? = nil,
        prompt: String? = nil, message: String? = nil, action: String? = nil,
        agentError: Bool? = nil, lineage: [AgentLineageEntry] = []
    ) {
        self.agent = agent
        self.event = event
        self.agentSessionId = agentSessionId
        self.cwd = cwd
        self.prompt = prompt
        self.message = message
        self.action = action
        self.agentError = agentError
        self.lineage = lineage
    }
}

/// Registry of coding-agent sessions observed via hooks
/// (docs/AGENT_MONITORING_DESIGN.md). Applies the agent state machine,
/// resolves ownership against daemon-owned PTYs (the hard dedup rule: an
/// agent appears either inside its terminal row or in the standalone Agents
/// section, never both), sweeps dead agents, and publishes debounced
/// `[AgentInfo]` snapshots. Thread-safe; all state lives on a serial queue.
public final class AgentMonitor: @unchecked Sendable {
    public struct Tuning: Sendable {
        /// Trailing-edge publish coalescing, so PreToolUse storms do not spam
        /// the relay (and downstream APNs budgets).
        public var debounce: TimeInterval = 0.4
        public var sweepInterval: TimeInterval = 2
        /// Records with no resolvable agent pid cannot be liveness-checked;
        /// they expire this long after their last event.
        public var idleExpiry: TimeInterval = 30 * 60
        /// Hard ceiling for any record, pid or not.
        public var absoluteTTL: TimeInterval = 24 * 60 * 60
        /// A `done` edge is held back this long before its attention update, and
        /// any state edge in the window cancels it. Claude fires Stop whenever
        /// its main loop parks — including mid-task waits on background
        /// subagents — so an immediate "finished" alert is often a lie; a park
        /// that resumes inside the window now alerts nothing. waiting/error
        /// alerts stay immediate. Only attention is delayed — the E2EE list
        /// snapshot still shows `done` in real time.
        public var doneAttentionDelay: TimeInterval = 30

        public init() {}
    }

    /// Field caps, re-applied here even though the reporter already caps:
    /// the socket is 0600 but its input is still treated as untrusted.
    static let promptCap = 200
    static let actionCap = 120
    static let messageCap = 300
    static let cwdCap = 1024
    static let idCap = 128
    static let lineageCap = 15

    private final class Record {
        let id: String
        let agent: String
        var state: AgentState = .running
        var cwd = ""
        var prompt: String?
        var action: String?
        var message: String?
        var updatedAt = Date()
        let firstSeenAt = Date()
        /// First non-shell ancestor in the reported lineage: the agent
        /// process itself, used for the liveness sweep.
        var agentPid: pid_t?
        var tty: String?
        var lineagePids: [pid_t] = []
        /// Terminal app display name; computed even for managed agents so an
        /// unmatch (session closed under a live agent) can surface it.
        var term: String?
        /// Managed match: the daemon session this agent runs inside.
        var sessionId: Int?

        init(id: String, agent: String) {
            self.id = id
            self.agent = agent
        }

        var info: AgentInfo {
            AgentInfo(
                id: id, agent: agent, state: state, cwd: cwd,
                action: action, message: message, prompt: prompt,
                sessionId: sessionId,
                term: sessionId == nil ? term : nil,
                updatedAt: updatedAt.timeIntervalSince1970
            )
        }
    }

    private let queue = DispatchQueue(label: "air.build.pedals.agents")
    private let tuning: Tuning
    private let matchTargets: @Sendable () -> [SessionManager.AgentMatchTarget]
    private var records: [String: Record] = [:]
    /// Held-back done attention events by agent id (see Tuning.doneAttentionDelay).
    private var pendingDoneAttention: [String: DispatchWorkItem] = [:]
    private var sweepTimer: DispatchSourceTimer?
    private var publishPending = false

    /// Delivered on the monitor's serial queue with the full sorted snapshot.
    public var onChange: (@Sendable ([AgentInfo]) -> Void)? {
        get { queue.sync { _onChange } }
        set { queue.sync { _onChange = newValue } }
    }
    private var _onChange: (@Sendable ([AgentInfo]) -> Void)?

    /// Fired on the monitor's serial queue when an agent transitions INTO a
    /// user-facing state (waiting/error/done) — edge-triggered, so repeated
    /// events in the same state (Claude's ask followed by its Notification
    /// hook) collapse to one attention event. Not debounced: transitions are
    /// rare and each deserves a visible Live Activity update.
    public var onAttention: (@Sendable (AgentInfo, AgentActivity.Attention) -> Void)? {
        get { queue.sync { _onAttention } }
        set { queue.sync { _onAttention = newValue } }
    }
    private var _onAttention: (@Sendable (AgentInfo, AgentActivity.Attention) -> Void)?

    public init(
        tuning: Tuning = Tuning(),
        matchTargets: @escaping @Sendable () -> [SessionManager.AgentMatchTarget]
    ) {
        self.tuning = tuning
        self.matchTargets = matchTargets
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + tuning.sweepInterval, repeating: tuning.sweepInterval
        )
        timer.setEventHandler { [weak self] in self?.sweepLocked() }
        timer.resume()
        sweepTimer = timer
    }

    deinit {
        sweepTimer?.cancel()
    }

    // MARK: - Public API

    public func ingest(_ event: AgentEvent) {
        queue.sync {
            let id = Self.sanitize(event.agentSessionId, cap: Self.idCap)
            let agent = Self.sanitize(event.agent, cap: 32)
            guard !id.isEmpty, !agent.isEmpty else { return }

            if event.event == "session-end" {
                pendingDoneAttention.removeValue(forKey: id)?.cancel()
                guard records.removeValue(forKey: id) != nil else { return }
                schedulePublishLocked()
                return
            }
            guard Self.knownEvents.contains(event.event) else { return }

            let record: Record
            if let existing = records[id] {
                record = existing
            } else {
                record = Record(id: id, agent: agent)
                records[id] = record
            }
            let oldState = record.state
            apply(event, to: record)
            applyLineage(event.lineage, to: record)
            _ = resolveOwnershipLocked(record, targets: matchTargets())
            record.updatedAt = Date()
            if record.state != oldState {
                // Any state edge supersedes held-back completion attention: the park
                // resumed (running), or something more urgent replaced it.
                pendingDoneAttention.removeValue(forKey: id)?.cancel()
                if let attention = Self.attention(record.state) {
                    if attention == .done {
                        scheduleDoneAttentionLocked(id: id)
                    } else {
                        _onAttention?(record.info, attention)
                    }
                }
            }
            schedulePublishLocked()
        }
    }

    /// States whose entry edge deserves visible attention. `.running` does not.
    private static func attention(_ state: AgentState) -> AgentActivity.Attention? {
        switch state {
        case .waiting: .waiting
        case .error: .error
        case .done: .done
        case .running: nil
        }
    }

    /// Delivers completion attention only if the agent is still done once the
    /// hold-back window closes; the record is re-read at fire time so the
    /// update carries the freshest message, and a record that vanished
    /// (session end, dismiss, sweep) alerts nothing.
    private func scheduleDoneAttentionLocked(id: String) {
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            pendingDoneAttention.removeValue(forKey: id)
            guard let record = records[id], record.state == .done else { return }
            _onAttention?(record.info, .done)
        }
        pendingDoneAttention[id] = item
        queue.asyncAfter(deadline: .now() + tuning.doneAttentionDelay, execute: item)
    }

    /// Current snapshot, most recently updated first.
    public func list() -> [AgentInfo] {
        queue.sync { listLocked() }
    }

    /// Client-requested dismissal (the Home list is bidirectional): removes
    /// the record for every client. The agent's next hook event recreates
    /// it, so a dismissed-but-alive agent reappears on its next state
    /// change. No attention event fires for the removal.
    public func dismiss(id: String) {
        queue.sync {
            pendingDoneAttention.removeValue(forKey: id)?.cancel()
            guard records.removeValue(forKey: id) != nil else { return }
            schedulePublishLocked()
        }
    }

    // MARK: - State machine (on `queue`)

    private static let knownEvents: Set<String> = [
        "session-start", "prompt", "tool", "busy", "ask", "notify", "compact",
        "stop",
    ]

    private func apply(_ event: AgentEvent, to record: Record) {
        if let cwd = event.cwd {
            let cleaned = Self.sanitize(cwd, cap: Self.cwdCap)
            if !cleaned.isEmpty { record.cwd = cleaned }
        }
        // `.error` is sticky: only a turn start (`prompt` or `busy`), a
        // session start, or another stop may move the agent out of it — a
        // mid-error `notify` (e.g. the idle notification) must not mask the
        // failure.
        let sticky = record.state == .error
        switch event.event {
        case "session-start":
            record.state = .running
            record.prompt = nil
            record.action = nil
            record.message = nil
        case "prompt":
            record.state = .running
            record.prompt = event.prompt.map { Self.sanitize($0, cap: Self.promptCap) }
            record.action = nil
            record.message = nil
        case "busy":
            // Turn-start signal from agents that carry no prompt text: back
            // to running (clearing error stickiness) but leave
            // prompt/action/message untouched.
            record.state = .running
        case "tool":
            if !sticky { record.state = .running }
            // nil action (agents without tool detail) keeps the last one.
            if let action = event.action {
                record.action = Self.sanitize(action, cap: Self.actionCap)
            }
        case "ask":
            if !sticky { record.state = .waiting }
            let provided = event.message.map { Self.sanitize($0, cap: Self.messageCap) }
            record.message = provided?.isEmpty == false ? provided : "Waiting for your answer"
        case "notify":
            // `.done` is sticky against notify too: Claude fires its idle
            // Notification hook ("waiting for your input") when the REPL
            // sits unattended after a Stop, and that must not resurrect a
            // finished agent into waiting — the push would read "needs your
            // input" right on the heels of "finished". A genuine ask always
            // happens mid-turn, after a turn start reset the state.
            guard record.state != .done else { break }
            if !sticky { record.state = .waiting }
            if let message = event.message {
                record.message = Self.sanitize(message, cap: Self.messageCap)
            }
        case "compact":
            if !sticky { record.state = .running }
            record.action = "Compacting context"
        case "stop":
            record.state = event.agentError == true ? .error : .done
            record.action = nil
            // A stop without text (some agents' stop path has no message
            // source) must not wipe the message we already have.
            if let message = event.message {
                record.message = Self.sanitize(message, cap: Self.messageCap)
            }
        default:
            break
        }
    }

    private func applyLineage(_ lineage: [AgentLineageEntry], to record: Record) {
        guard !lineage.isEmpty else { return } // keep the previous lineage
        let entries = Array(lineage.prefix(Self.lineageCap))
        record.lineagePids = entries.map(\.pid).filter { $0 > 0 }
        record.tty = entries.compactMap(\.tty).first
        record.agentPid = entries.first {
            $0.pid > 0 && !Self.isShell(processName: $0.name)
        }?.pid
        record.term = entries.compactMap {
            Self.terminalDisplayName(processName: $0.name)
        }.first
    }

    // MARK: - Ownership matching (on `queue`)

    /// The dedup hard rule: tty equality with a daemon PTY slave path first,
    /// else a daemon shell pid inside the lineage. Returns whether the match
    /// changed.
    private func resolveOwnershipLocked(
        _ record: Record, targets: [SessionManager.AgentMatchTarget]
    ) -> Bool {
        var matched: Int?
        if let tty = record.tty {
            matched = targets.first { $0.ttyPath == tty }?.sessionId
        }
        if matched == nil {
            let pids = Set(record.lineagePids)
            matched = targets.first { pids.contains($0.shellPid) }?.sessionId
        }
        guard matched != record.sessionId else { return false }
        record.sessionId = matched
        return true
    }

    // MARK: - Liveness sweep (on `queue`)

    private func sweepLocked() {
        let targets = matchTargets()
        let now = Date()
        var changed = false
        for (id, record) in records {
            if let pid = record.agentPid, pid > 0 {
                if kill(pid, 0) != 0 && errno == ESRCH {
                    records.removeValue(forKey: id)
                    changed = true
                    continue
                }
            } else if now.timeIntervalSince(record.updatedAt) > tuning.idleExpiry {
                records.removeValue(forKey: id)
                changed = true
                continue
            }
            if now.timeIntervalSince(record.firstSeenAt) > tuning.absoluteTTL {
                records.removeValue(forKey: id)
                changed = true
                continue
            }
            // A session can close while the agent lives on (or appear after
            // the agent's first event): recompute the match both ways.
            if resolveOwnershipLocked(record, targets: targets) {
                record.updatedAt = now
                changed = true
            }
        }
        if changed { schedulePublishLocked() }
    }

    /// Deterministic sweep for tests.
    func sweepNow() {
        queue.sync { sweepLocked() }
    }

    // MARK: - Debounced publish (on `queue`)

    private func schedulePublishLocked() {
        guard !publishPending else { return }
        publishPending = true
        queue.asyncAfter(deadline: .now() + tuning.debounce) { [weak self] in
            guard let self else { return }
            self.publishPending = false
            self._onChange?(self.listLocked())
        }
    }

    private func listLocked() -> [AgentInfo] {
        records.values
            .sorted { ($0.updatedAt, $0.id) > ($1.updatedAt, $1.id) }
            .map(\.info)
    }

    // MARK: - Helpers

    private static let shellNames: Set<String> = [
        "sh", "bash", "zsh", "dash", "fish", "login",
    ]

    static func isShell(processName: String) -> Bool {
        var name = processName.lowercased()
        if name.hasPrefix("-") { name.removeFirst() } // login-shell argv style
        return shellNames.contains(name)
    }

    /// Known terminal apps by `p_comm` → display name. `p_comm` is capped at
    /// 16 bytes by the kernel, so a 16-char reported name also matches as a
    /// prefix of the known longer name.
    static func terminalDisplayName(processName: String) -> String? {
        let name = processName.lowercased()
        let known: [(comm: String, display: String)] = [
            ("iterm2", "iTerm"),
            ("apple_terminal", "Terminal"),
            ("terminal", "Terminal"),
            ("ghostty", "Ghostty"),
            ("wezterm-gui", "WezTerm"),
            ("wezterm", "WezTerm"),
            ("alacritty", "Alacritty"),
            ("kitty", "kitty"),
            ("tmux", "tmux"),
            ("code helper (plugin)", "VS Code"),
            ("code helper", "VS Code"),
            ("code", "VS Code"),
            ("electron", "VS Code"),
            ("warp", "Warp"),
        ]
        for (comm, display) in known {
            if name == comm { return display }
            if name.utf8.count == 16 && comm.hasPrefix(name) { return display }
        }
        return nil
    }

    /// Strips C0 controls (and DEL) and caps length; the reporter applies the
    /// same treatment before sending.
    static func sanitize(_ value: String, cap: Int) -> String {
        var out = ""
        for scalar in value.unicodeScalars {
            if out.count >= cap { break }
            if scalar.value < 0x20 || scalar.value == 0x7F {
                out.append(" ")
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }
}
