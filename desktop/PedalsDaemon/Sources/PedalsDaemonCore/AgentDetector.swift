import Foundation

/// Hook-free agent state detection.
///
/// Design constraints (deliberate):
/// - **Identity comes from the foreground process name only** (the whole
///   process group — a CLI often shares the shell's group). User input and
///   chat output cannot forge a `p_comm`.
/// - **State reads a reconstructed live screen, never the raw stream.** A
///   `ScreenGrid` replays cursor motion so overwrites land in place; the
///   visible grid is the current footer/dialog with no stale history and no
///   echoed-input contamination (input lands where the cursor is, as in a real
///   terminal). Working/blocked patterns are narrow, structured shapes (token
///   counters, selector rows) that chat prose can't reproduce.
/// - App-emitted out-of-band signals are preferred where available: OSC 9;4
///   progress (oh-my-pi, some Claude builds) is unforgeable by screen content.
///
/// Verified signals (captured from real CLIs):
/// - Claude Code: ✳ is a permanent title brand (NOT a busy flag); streaming
///   footer "<verb>… (6s · ↓19 tokens)" ⇒ working, "<verb> for Ns" ⇒ done;
///   approval "❯ 1. Yes …" / "Do you want to …" ⇒ blocked. Runs in the shell's
///   process group (pgid == shell pid).
/// - Codex: no OSC title (openai/codex#21958), no OSC 9;4; footer
///   "• Working (12s • esc to interrupt)"; approval "› 1. Yes, proceed (y)".
/// - oh-my-pi: OSC 9;4 indeterminate while running (packages/tui terminal.ts);
///   plan approval "Approve and …".
public enum AgentState: String, Sendable {
    case idle
    case working
    case blocked
}

/// A process in the session's foreground process group (pid + parent + comm),
/// enough to reconstruct the agent nesting.
public struct ProcessEntry: Equatable, Sendable {
    public let pid: Int32
    public let ppid: Int32
    public let comm: String
    public init(pid: Int32, ppid: Int32, comm: String) {
        self.pid = pid
        self.ppid = ppid
        self.comm = comm
    }
}

public struct AgentRule: @unchecked Sendable {
    public let id: String
    /// Exact `p_comm` names identifying this agent — the ONLY identity source.
    public let processNames: Set<String>
    /// App-emitted OSC title prefixes meaning "busy".
    public let busyTitlePrefixes: [String]
    /// Whether OSC 9;4 set/indeterminate implies working.
    public let honorsProgress: Bool
    /// Regexes over the ANSI-stripped, lowercased bottom tail ⇒ working.
    public let workingPatterns: [NSRegularExpression]
    /// Regexes over the same text ⇒ blocked (checked before working).
    public let blockedPatterns: [NSRegularExpression]

    init(
        id: String,
        processNames: Set<String>,
        busyTitlePrefixes: [String] = [],
        honorsProgress: Bool,
        workingPatterns: [String] = [],
        blockedPatterns: [String] = []
    ) {
        self.id = id
        self.processNames = processNames
        self.busyTitlePrefixes = busyTitlePrefixes
        self.honorsProgress = honorsProgress
        self.workingPatterns = workingPatterns.compactMap {
            try? NSRegularExpression(pattern: $0)
        }
        self.blockedPatterns = blockedPatterns.compactMap {
            try? NSRegularExpression(pattern: $0)
        }
    }

    public static let builtin: [AgentRule] = [
        // Patterns run over the reconstructed bottom-of-screen text (see
        // ScreenGrid) — the live footer/dialog, not stream history. Spaces in
        // the grid are real columns, but agents pad with cursor moves too, so
        // inter-token gaps stay `\s*` for safety.
        AgentRule(
            id: "claude-code",
            processNames: ["claude"],
            busyTitlePrefixes: [], // ✳ is claude's permanent title brand, not a busy flag
            honorsProgress: true,  // used if a build emits OSC 9;4; harmless otherwise
            workingPatterns: [
                // Live status footer "<spinner-word>… (6s · ↓19 tokens)". The
                // "(Ns · …tokens)" live counter renders only while streaming;
                // when done the footer becomes "<verb> for Ns" (no counter).
                // The structured shape can't be produced by prose/chat output.
                "\\(\\d+s\\s*·[^)]*tokens?[^)]*\\)",
            ],
            blockedPatterns: [
                // "❯ 1. Yes" / "❯ 2. Yes, and don't ask again" selector rows.
                "❯\\s*\\d\\.\\s*yes",
                "do you want to (proceed|make|run|create|allow)",
            ]
        ),
        AgentRule(
            id: "codex",
            processNames: ["codex"],
            honorsProgress: false, // codex emits neither title nor OSC 9;4
            workingPatterns: [
                // "• Working (12s • esc to interrupt)" — timer + hint together.
                // A bare "esc to interrupt" is avoided: the agent could print
                // those words in chat. The "(Ns … esc to interrupt)" shape can't.
                "\\(\\d+[ms][^)]*esc\\s*to\\s*interrupt\\)",
            ],
            blockedPatterns: [
                "›\\s*\\d\\.\\s*yes,\\s*proceed",
                "would you like to[^›]{0,160}›\\s*\\d\\.",
            ]
        ),
        AgentRule(
            id: "oh-my-pi",
            processNames: ["pi", "omp", "oh-my-pi"],
            honorsProgress: true, // emits OSC 9;4 keepalive while running (verified in tui)
            // Working relies on the app-emitted OSC 9;4 progress — the cleanest,
            // interference-free signal — so no screen text pattern is needed.
            workingPatterns: [],
            blockedPatterns: [
                "approve\\s*and\\s*(execute|keep\\s*context|compact)",
            ]
        ),
    ]
}

/// Per-session tracker. Not thread-safe on its own — the owner
/// (`SessionManager`) always calls it on its serial queue.
public final class AgentStateTracker {
    private let rules: [AgentRule]

    /// Live screen model — the bottom rows are the current footer/dialog.
    private let screen = ScreenGrid()

    /// OSC 9;4 progress state (true while set/indeterminate/error).
    private var progressActive = false
    /// Timestamp of the last standalone BEL (not an OSC terminator).
    public private(set) var lastBell: Date?

    /// The foreground process group (a CLI often shares the shell's group, so
    /// the group leader is the shell, not the agent). Identity picks the
    /// TOP-MOST agent — the one the user actually interacts with — when agents
    /// are nested (claude spawning codex ⇒ claude).
    private var fgProcesses: [ProcessEntry] = []
    private var title = ""

    public init(rules: [AgentRule] = AgentRule.builtin) {
        self.rules = rules
    }

    // MARK: - Inputs

    public func noteOutput(_ data: Data) {
        scanSignals(data)
        screen.feed(data)
    }

    public func noteResize(cols: Int, rows: Int) {
        screen.resize(rows: rows, cols: cols)
    }

    public func noteTitle(_ title: String) {
        self.title = title
    }

    public func noteForegroundProcesses(_ procs: [ProcessEntry]) {
        fgProcesses = procs
    }

    /// Test/convenience entry for a flat sibling list (no nesting).
    public func noteForegroundProcesses(names: [String]) {
        fgProcesses = names.enumerated().map {
            ProcessEntry(pid: Int32($0.offset + 2), ppid: 1, comm: $0.element)
        }
    }

    // MARK: - Evaluation

    public struct Verdict: Equatable, Sendable {
        public let agent: String?
        public let state: AgentState
    }

    public func evaluate() -> Verdict {
        guard let rule = identifyTopmostAgent() else {
            return Verdict(agent: nil, state: .idle)
        }

        let text = screen.visibleText()
        let range = NSRange(text.startIndex..., in: text)

        if rule.blockedPatterns.contains(where: {
            $0.firstMatch(in: text, range: range) != nil
        }) {
            return Verdict(agent: rule.id, state: .blocked)
        }

        let busyByTitle = rule.busyTitlePrefixes.contains { title.hasPrefix($0) }
        let busyByProgress = rule.honorsProgress && progressActive
        let busyByScreen = rule.workingPatterns.contains {
            $0.firstMatch(in: text, range: range) != nil
        }
        if busyByTitle || busyByProgress || busyByScreen {
            return Verdict(agent: rule.id, state: .working)
        }
        return Verdict(agent: rule.id, state: .idle)
    }

    /// The rule for the top-most agent in the process group: the agent the user
    /// is actually interacting with. When agents nest (claude spawns codex as a
    /// tool subprocess), the child is not what the user drives, so the agent
    /// whose parent is NOT itself a known agent wins. Ties (independent agents
    /// in one group — rare) break to the earliest-started (smallest pid).
    private func identifyTopmostAgent() -> AgentRule? {
        // Each process that is a known agent, paired with its rule.
        let agents = fgProcesses.compactMap { proc -> (ProcessEntry, AgentRule)? in
            let name = proc.comm.lowercased()
            guard let rule = rules.first(where: { $0.processNames.contains(name) })
            else { return nil }
            return (proc, rule)
        }
        guard !agents.isEmpty else { return nil }

        let agentPids = Set(agents.map(\.0.pid))
        let topmost = agents.filter { !agentPids.contains($0.0.ppid) }
        return (topmost.isEmpty ? agents : topmost)
            .min { $0.0.pid < $1.0.pid }?.1
    }

    // MARK: - Stream signal scanning

    /// Finds OSC 9;4 progress updates and standalone BELs in a raw chunk.
    private func scanSignals(_ data: Data) {
        let bytes = [UInt8](data)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x1b, index + 1 < bytes.count, bytes[index + 1] == 0x5d {
                // OSC … terminated by BEL or ESC \
                var end = index + 2
                var payload = [UInt8]()
                while end < bytes.count {
                    let b = bytes[end]
                    if b == 0x07 { break }
                    if b == 0x1b, end + 1 < bytes.count, bytes[end + 1] == 0x5c {
                        end += 1
                        break
                    }
                    payload.append(b)
                    end += 1
                }
                let text = String(decoding: payload, as: UTF8.self)
                if text.hasPrefix("9;4;") {
                    // 9;4;<state>[;<progress>] — state 0 clears, others active.
                    let fields = text.dropFirst(4).split(separator: ";")
                    progressActive = fields.first.map { $0 != "0" } ?? false
                }
                index = end + 1
                continue
            }
            if byte == 0x07 {
                lastBell = Date()
            }
            index += 1
        }
    }

}
