import Darwin
import Foundation
import PedalsKit
import XCTest

@testable import PedalsDaemonCore

/// AgentMonitor state machine, ownership dedup, liveness, and debounce.
final class AgentMonitorTests: XCTestCase {
    /// Mutable match-target source standing in for the SessionManager.
    private final class Targets: @unchecked Sendable {
        private let lock = NSLock()
        private var value: [SessionManager.AgentMatchTarget] = []
        var current: [SessionManager.AgentMatchTarget] {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    private var targets: Targets!
    private var monitor: AgentMonitor!

    override func setUp() {
        targets = Targets()
        var tuning = AgentMonitor.Tuning()
        tuning.debounce = 0.08
        // Long enough that the periodic sweep never interferes with tests,
        // which drive sweeps explicitly via `sweepNow()`.
        tuning.sweepInterval = 3600
        tuning.doneAttentionDelay = 0.1
        monitor = AgentMonitor(tuning: tuning) { [targets] in targets!.current }
    }

    /// Sleeps past the test's done hold-back window (0.1s) so a held done
    /// push either lands or is proven cancelled.
    private func waitPastDoneDelay() {
        let expectation = expectation(description: "done hold-back elapsed")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
    }

    /// A live pid: our own test process, so kill(pid, 0) always succeeds.
    private var livePid: Int32 { getpid() }

    private func event(
        _ event: String, id: String = "a-1", cwd: String? = "/tmp/p",
        prompt: String? = nil, message: String? = nil, action: String? = nil,
        agentError: Bool? = nil, lineage: [AgentLineageEntry]? = nil
    ) -> AgentEvent {
        AgentEvent(
            agent: "claude", event: event, agentSessionId: id, cwd: cwd,
            prompt: prompt, message: message, action: action,
            agentError: agentError,
            lineage: lineage ?? [AgentLineageEntry(pid: livePid, name: "claude")]
        )
    }

    private func only() throws -> AgentInfo {
        let list = monitor.list()
        XCTAssertEqual(list.count, 1)
        return try XCTUnwrap(list.first)
    }

    // MARK: - State machine

    func testStateMachineTransitions() throws {
        monitor.ingest(event("session-start"))
        XCTAssertEqual(try only().state, .running)

        monitor.ingest(event("prompt", prompt: "fix the tests"))
        var info = try only()
        XCTAssertEqual(info.state, .running)
        XCTAssertEqual(info.prompt, "fix the tests")

        monitor.ingest(event("tool", action: "Bash: swift test"))
        info = try only()
        XCTAssertEqual(info.state, .running)
        XCTAssertEqual(info.action, "Bash: swift test")

        monitor.ingest(event("ask"))
        info = try only()
        XCTAssertEqual(info.state, .waiting)
        XCTAssertEqual(info.message, "Waiting for your answer")

        monitor.ingest(event("notify", message: "Permission needed"))
        info = try only()
        XCTAssertEqual(info.state, .waiting)
        XCTAssertEqual(info.message, "Permission needed")

        monitor.ingest(event("compact"))
        info = try only()
        XCTAssertEqual(info.state, .running)
        XCTAssertEqual(info.action, "Compacting context")

        monitor.ingest(event("stop", message: "All done."))
        info = try only()
        XCTAssertEqual(info.state, .done)
        XCTAssertEqual(info.message, "All done.")

        monitor.ingest(event("session-end"))
        XCTAssertTrue(monitor.list().isEmpty)
    }

    func testPromptClearsActionAndMessage() throws {
        monitor.ingest(event("tool", action: "Bash: ls"))
        monitor.ingest(event("notify", message: "hello"))
        monitor.ingest(event("prompt", prompt: "next"))
        let info = try only()
        XCTAssertNil(info.action)
        XCTAssertNil(info.message)
    }

    func testStopWithAgentErrorAndStickiness() throws {
        monitor.ingest(event("prompt", prompt: "run"))
        monitor.ingest(event("stop", message: "API Error: 500", agentError: true))
        var info = try only()
        XCTAssertEqual(info.state, .error)
        XCTAssertEqual(info.message, "API Error: 500")

        // A notify (e.g. the idle notification) must not mask the failure.
        monitor.ingest(event("notify", message: "Claude is waiting"))
        XCTAssertEqual(try only().state, .error)

        // A new prompt clears it…
        monitor.ingest(event("prompt", prompt: "again"))
        XCTAssertEqual(try only().state, .running)

        // …and so does a session start.
        monitor.ingest(event("stop", agentError: true))
        XCTAssertEqual(try only().state, .error)
        monitor.ingest(event("session-start"))
        info = try only()
        XCTAssertEqual(info.state, .running)
        XCTAssertNil(info.message)
    }

    func testBusyPreservesContextAndClearsError() throws {
        monitor.ingest(event("prompt", prompt: "ship it"))
        monitor.ingest(event("tool", action: "Bash: swift test"))
        monitor.ingest(event("busy"))
        var info = try only()
        XCTAssertEqual(info.state, .running)
        XCTAssertEqual(info.prompt, "ship it", "busy leaves prompt untouched")
        XCTAssertEqual(info.action, "Bash: swift test", "busy leaves action untouched")

        // busy is a turn-start signal: it clears error stickiness…
        monitor.ingest(event("stop", message: "API Error: 500", agentError: true))
        XCTAssertEqual(try only().state, .error)
        monitor.ingest(event("busy"))
        info = try only()
        XCTAssertEqual(info.state, .running)
        // …but leaves the last message in place (unlike prompt).
        XCTAssertEqual(info.message, "API Error: 500")
    }

    func testBusyCreatesRecord() throws {
        monitor.ingest(event("busy"))
        XCTAssertEqual(try only().state, .running)
    }

    func testStopWithNilMessagePreservesMessage() throws {
        monitor.ingest(event("notify", message: "Needs review"))
        monitor.ingest(event("stop"))
        let info = try only()
        XCTAssertEqual(info.state, .done)
        XCTAssertEqual(info.message, "Needs review")

        // A provided message still replaces it.
        monitor.ingest(event("stop", message: "All wrapped up"))
        XCTAssertEqual(try only().message, "All wrapped up")
    }

    func testToolWithNilActionPreservesAction() throws {
        monitor.ingest(event("tool", action: "Bash: swift build"))
        monitor.ingest(event("tool"))
        let info = try only()
        XCTAssertEqual(info.state, .running)
        XCTAssertEqual(info.action, "Bash: swift build")
    }

    func testUnknownEventIgnored() {
        monitor.ingest(event("frobnicate"))
        XCTAssertTrue(monitor.list().isEmpty)
    }

    func testFieldsCappedDefensively() throws {
        monitor.ingest(event(
            "prompt",
            cwd: String(repeating: "d", count: 5000),
            prompt: String(repeating: "p", count: 5000)
        ))
        monitor.ingest(event("tool", cwd: nil, action: String(repeating: "a", count: 5000)))
        monitor.ingest(event(
            "notify", cwd: nil, message: "x\u{07}y" + String(repeating: "m", count: 5000)
        ))
        let info = try only()
        XCTAssertEqual(info.cwd.count, 1024)
        XCTAssertEqual(info.prompt?.count, 200)
        XCTAssertEqual(info.action?.count, 120)
        XCTAssertEqual(info.message?.count, 300)
        XCTAssertFalse(info.message!.unicodeScalars.contains { $0.value < 0x20 })
    }

    // MARK: - Ownership matching

    func testMatchByTTY() throws {
        targets.current = [
            .init(sessionId: 7, ttyPath: "/dev/ttys009", shellPid: 4242)
        ]
        monitor.ingest(event("prompt", lineage: [
            AgentLineageEntry(pid: livePid, name: "claude", tty: "/dev/ttys009")
        ]))
        let info = try only()
        XCTAssertEqual(info.sessionId, 7)
        XCTAssertNil(info.term, "managed agents carry no terminal-app name")
    }

    func testMatchByShellPidInLineage() throws {
        targets.current = [
            .init(sessionId: 3, ttyPath: "/dev/ttys001", shellPid: 4242)
        ]
        monitor.ingest(event("prompt", lineage: [
            AgentLineageEntry(pid: livePid, name: "claude", tty: "/dev/ttys777"),
            AgentLineageEntry(pid: 4242, name: "zsh", tty: "/dev/ttys777"),
        ]))
        XCTAssertEqual(try only().sessionId, 3)
    }

    func testUnmanagedAgentCarriesTerminalName() throws {
        monitor.ingest(event("prompt", lineage: [
            AgentLineageEntry(pid: livePid, name: "claude", tty: "/dev/ttys004"),
            AgentLineageEntry(pid: 4243, name: "zsh", tty: "/dev/ttys004"),
            AgentLineageEntry(pid: 4244, name: "iTerm2"),
        ]))
        let info = try only()
        XCTAssertNil(info.sessionId)
        XCTAssertEqual(info.term, "iTerm")
    }

    func testUnmatchWhenSessionCloses() throws {
        targets.current = [
            .init(sessionId: 7, ttyPath: "/dev/ttys009", shellPid: 4242)
        ]
        monitor.ingest(event("prompt", lineage: [
            AgentLineageEntry(pid: livePid, name: "claude", tty: "/dev/ttys009"),
            AgentLineageEntry(pid: 4244, name: "ghostty"),
        ]))
        XCTAssertEqual(try only().sessionId, 7)

        // Session closes under the still-living agent → unmanaged.
        targets.current = []
        monitor.sweepNow()
        let info = try only()
        XCTAssertNil(info.sessionId)
        XCTAssertEqual(info.term, "Ghostty")
    }

    func testTerminalNameTruncatedCommMatches() {
        XCTAssertEqual(
            AgentMonitor.terminalDisplayName(processName: "Code Helper (Plu"),
            "VS Code"
        )
        XCTAssertEqual(AgentMonitor.terminalDisplayName(processName: "tmux"), "tmux")
        XCTAssertNil(AgentMonitor.terminalDisplayName(processName: "systemd"))
    }

    // MARK: - Liveness

    func testDeadAgentPidRemovedOnSweep() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["0.01"]
        try process.run()
        process.waitUntilExit()
        let deadPid = process.processIdentifier

        monitor.ingest(event("prompt", lineage: [
            AgentLineageEntry(pid: deadPid, name: "claude")
        ]))
        XCTAssertEqual(monitor.list().count, 1)
        monitor.sweepNow()
        XCTAssertTrue(monitor.list().isEmpty)
    }

    func testLiveAgentPidSurvivesSweep() {
        monitor.ingest(event("prompt"))
        monitor.sweepNow()
        XCTAssertEqual(monitor.list().count, 1)
    }

    // MARK: - Debounce

    func testTwoIngestsWithinWindowPublishOnce() {
        let counter = Counter()
        monitor.onChange = { _ in counter.increment() }
        monitor.ingest(event("prompt", prompt: "one"))
        monitor.ingest(event("tool", action: "Bash: ls"))

        let expectation = expectation(description: "debounce window elapsed")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
        XCTAssertEqual(counter.value, 1)
    }

    func testPublishCarriesSortedSnapshot() {
        let received = Received()
        monitor.onChange = { received.append($0) }
        monitor.ingest(event("prompt", id: "a-1"))
        monitor.ingest(event("prompt", id: "a-2"))

        let expectation = expectation(description: "debounce window elapsed")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
        let last = received.all.last
        XCTAssertEqual(last?.count, 2)
        XCTAssertEqual(last?.first?.id, "a-2", "most recently updated first")
    }

    // MARK: - Live Activity attention transitions

    private final class Updates: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [(info: AgentInfo, attention: AgentActivity.Attention)] = []
        var all: [(info: AgentInfo, attention: AgentActivity.Attention)] { lock.withLock { events } }
        func append(_ info: AgentInfo, _ attention: AgentActivity.Attention) {
            lock.withLock { events.append((info, attention)) }
        }
    }

    func testAttentionFiresOnEntryEdgesOnly() {
        let updates = Updates()
        monitor.onAttention = { updates.append($0, $1) }

        monitor.ingest(event("session-start"))
        monitor.ingest(event("prompt", prompt: "go"))
        XCTAssertTrue(updates.all.isEmpty, "running states never notify")

        // Claude fires ask (PreToolUse) and then notify (Notification hook)
        // for the same question: one notification, not two.
        monitor.ingest(event("ask"))
        monitor.ingest(event("notify", message: "Permission needed"))
        XCTAssertEqual(updates.all.count, 1)
        XCTAssertEqual(updates.all.first?.attention, .waiting)
        XCTAssertEqual(updates.all.first?.info.message, "Waiting for your answer")

        // Answering (prompt) and a fresh ask is a new edge.
        monitor.ingest(event("prompt", prompt: "yes"))
        monitor.ingest(event("ask", message: "Pick a plan"))
        XCTAssertEqual(updates.all.count, 2)
        XCTAssertEqual(updates.all.last?.info.message, "Pick a plan")

        // Turn end reports done with the final message — after the hold-back
        // window, not on the edge itself.
        monitor.ingest(event("stop", message: "All tests pass"))
        XCTAssertEqual(updates.all.count, 2, "done is held back, not immediate")
        waitPastDoneDelay()
        XCTAssertEqual(updates.all.count, 3)
        XCTAssertEqual(updates.all.last?.attention, .done)
        XCTAssertEqual(updates.all.last?.info.message, "All tests pass")

        // A repeated stop in the same state is not an edge.
        monitor.ingest(event("stop"))
        waitPastDoneDelay()
        XCTAssertEqual(updates.all.count, 3)
    }

    func testAttentionFiresOnErrorStop() {
        let updates = Updates()
        monitor.onAttention = { updates.append($0, $1) }
        monitor.ingest(event("prompt", prompt: "go"))
        monitor.ingest(event("stop", agentError: true))
        XCTAssertEqual(updates.all.count, 1)
        XCTAssertEqual(updates.all.first?.attention, .error)

        // Sticky error: the idle notify must not re-notify (or downgrade).
        monitor.ingest(event("notify", message: "waiting for input"))
        XCTAssertEqual(updates.all.count, 1)
    }

    func testIdleNotifyAfterStopStaysDone() {
        let updates = Updates()
        monitor.onAttention = { updates.append($0, $1) }
        monitor.ingest(event("prompt", prompt: "go"))
        monitor.ingest(event("stop", message: "All tests pass"))

        // Claude's idle Notification hook fires ~60s after a finished turn;
        // it must not flip done back to waiting ("needs your input" right
        // after "finished"), overwrite the finish summary, or cancel the
        // held-back done push (the state did not change).
        monitor.ingest(event("notify", message: "Claude is waiting for your input"))
        waitPastDoneDelay()
        XCTAssertEqual(updates.all.count, 1)
        XCTAssertEqual(updates.all.first?.attention, .done)
        let info = monitor.list().first
        XCTAssertEqual(info?.state, .done)
        XCTAssertEqual(info?.message, "All tests pass")

        // The next turn still reaches waiting normally.
        monitor.ingest(event("prompt", prompt: "continue"))
        monitor.ingest(event("notify", message: "Permission needed"))
        XCTAssertEqual(updates.all.count, 2)
        XCTAssertEqual(updates.all.last?.attention, .waiting)
    }

    func testDonePushCancelledWhenParkedTurnResumes() {
        let updates = Updates()
        monitor.onAttention = { updates.append($0, $1) }

        // Claude parks waiting on a background subagent: Stop fires, then the
        // main loop resumes inside the hold-back window. No push at all.
        monitor.ingest(event("prompt", prompt: "go"))
        monitor.ingest(event("stop", message: "Launched the build agent"))
        monitor.ingest(event("tool", action: "Bash: swift test"))
        waitPastDoneDelay()
        XCTAssertTrue(updates.all.isEmpty, "resumed park must swallow the done push")

        // The real completion still lands after the window.
        monitor.ingest(event("stop", message: "All done"))
        waitPastDoneDelay()
        XCTAssertEqual(updates.all.count, 1)
        XCTAssertEqual(updates.all.first?.attention, .done)
        XCTAssertEqual(updates.all.first?.info.message, "All done")
    }

    func testDonePushCancelledByDismiss() {
        let updates = Updates()
        monitor.onAttention = { updates.append($0, $1) }
        monitor.ingest(event("prompt", prompt: "go"))
        monitor.ingest(event("stop"))
        monitor.dismiss(id: "a-1")
        waitPastDoneDelay()
        XCTAssertTrue(updates.all.isEmpty, "dismissing the agent cancels the held push")
    }

    func testSessionEndDoesNotNotify() {
        let updates = Updates()
        monitor.onAttention = { updates.append($0, $1) }
        monitor.ingest(event("prompt", prompt: "go"))
        monitor.ingest(AgentEvent(agent: "claude", event: "session-end", agentSessionId: "a-1"))
        XCTAssertTrue(updates.all.isEmpty)
        XCTAssertTrue(monitor.list().isEmpty)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var lists: [[AgentInfo]] = []
    var all: [[AgentInfo]] { lock.withLock { lists } }
    func append(_ list: [AgentInfo]) { lock.withLock { lists.append(list) } }
}

extension AgentMonitorTests {
    func testDismissRemovesRecordUntilNextEvent() throws {
        monitor.ingest(event("stop", message: "All done"))
        XCTAssertEqual(monitor.list().count, 1)

        monitor.dismiss(id: "a-1")
        XCTAssertTrue(monitor.list().isEmpty)

        // The agent's next hook event recreates the record.
        monitor.ingest(event("prompt", prompt: "again"))
        XCTAssertEqual(monitor.list().count, 1)
        XCTAssertEqual(monitor.list().first?.state, .running)
    }
}
