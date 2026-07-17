import Foundation
@testable import PedalsDaemonCore
import XCTest

final class AgentDetectorTests: XCTestCase {
    private func tracker() -> AgentStateTracker { AgentStateTracker() }

    // MARK: - Identity: foreground process name ONLY

    func testUnknownProcessIsNoAgent() {
        let t = tracker()
        t.noteForegroundProcesses(names: ["zsh"])
        t.noteOutput(Data("ls\r\nApplications Desktop\r\n".utf8))
        XCTAssertEqual(t.evaluate(), .init(agent: nil, state: .idle))
    }

    func testTitleAloneDoesNotIdentify() {
        let t = tracker()
        t.noteForegroundProcesses(names: ["zsh"])
        t.noteTitle("π") // user could fake this via printf
        XCTAssertEqual(t.evaluate().agent, nil)
    }

    func testAgentInsideSharedShellGroupIsFound() {
        // CLI keeps the shell's process group ⇒ both names appear together.
        let t = tracker()
        t.noteForegroundProcesses(names: ["zsh", "claude"])
        XCTAssertEqual(t.evaluate().agent, "claude-code")
    }

    func testProcessNameIdentifies() {
        for (proc, id) in [("claude", "claude-code"), ("codex", "codex"), ("pi", "oh-my-pi")] {
            let t = tracker()
            t.noteForegroundProcesses(names: [proc])
            XCTAssertEqual(t.evaluate(), .init(agent: id, state: .idle))
        }
    }

    // MARK: - Nested agents: the top-most (user-facing) agent wins

    func testClaudeSpawningCodexIdentifiesClaude() {
        // shell(10) → claude(11) → codex(12). User interacts with claude.
        let t = tracker()
        t.noteForegroundProcesses([
            .init(pid: 10, ppid: 1, comm: "zsh"),
            .init(pid: 11, ppid: 10, comm: "claude"),
            .init(pid: 12, ppid: 11, comm: "codex"),
        ])
        XCTAssertEqual(t.evaluate().agent, "claude-code")
    }

    func testCodexSpawningClaudeIdentifiesCodex() {
        // Reversed nesting: shell(10) → codex(11) → claude(12) ⇒ codex.
        // Proves identity follows the tree, not the rule-table order.
        let t = tracker()
        t.noteForegroundProcesses([
            .init(pid: 10, ppid: 1, comm: "zsh"),
            .init(pid: 11, ppid: 10, comm: "codex"),
            .init(pid: 12, ppid: 11, comm: "claude"),
        ])
        XCTAssertEqual(t.evaluate().agent, "codex")
    }

    func testTwoIndependentAgentsPicksEarliest() {
        // Both children of the shell (no nesting) — pick the earliest started.
        let t = tracker()
        t.noteForegroundProcesses([
            .init(pid: 10, ppid: 1, comm: "zsh"),
            .init(pid: 20, ppid: 10, comm: "codex"),
            .init(pid: 15, ppid: 10, comm: "claude"),
        ])
        XCTAssertEqual(t.evaluate().agent, "claude-code") // pid 15 < 20
    }

    // MARK: - Working: out-of-band signals

    func testClaudeWorkingFooter() {
        // Real captured footers, streaming state.
        for footer in [
            "✻ symbioting… (2s · ↓ 2 tokens)",
            "cogitating… (3s · ↓ 128 tokens · esc to interrupt)",
            "puzzling… (12s · ↑2.1k tokens)",
        ] {
            let t = tracker()
            t.noteForegroundProcesses(names: ["claude"])
            t.noteOutput(Data("\(footer)\r\n".utf8))
            XCTAssertEqual(
                t.evaluate(), .init(agent: "claude-code", state: .working), footer
            )
        }
    }

    func testClaudeDoneFooterIsIdle() {
        // Past-tense completion footer has no live counter ⇒ idle.
        let t = tracker()
        t.noteForegroundProcesses(names: ["claude"])
        t.noteOutput(Data("✻ cogitated for 4s\r\n❯ \r\n? for shortcuts\r\n".utf8))
        XCTAssertEqual(t.evaluate().state, .idle)
    }

    func testClaudeIdleDespiteStarTitle() {
        // ✳ is claude's permanent title brand; it must NOT imply working.
        let t = tracker()
        t.noteForegroundProcesses(names: ["claude"])
        t.noteTitle("✳ Write a haiku about the ocean")
        t.noteOutput(Data("⏺ baked for 6s\r\n\r\n❯ \r\n? for shortcuts\r\n".utf8))
        XCTAssertEqual(t.evaluate(), .init(agent: "claude-code", state: .idle))
    }

    func testClaudeWorkingThenIdleWhenFooterOverwritten() {
        let t = tracker()
        t.noteForegroundProcesses(names: ["claude"])
        t.noteOutput(Data("Warping… (6s · ↓19 tokens)\r".utf8))
        XCTAssertEqual(t.evaluate().state, .working)
        // Agent overwrites the footer line in place (CR) with the done state.
        t.noteOutput(Data("\u{1b}[2J⏺ done\r\n❯ \r\n? for shortcuts\r\n".utf8))
        XCTAssertEqual(t.evaluate().state, .idle)
    }

    func testProgressOSCMeansWorkingAndClears() {
        let t = tracker()
        t.noteForegroundProcesses(names: ["pi"])
        t.noteOutput(Data("\u{1b}]9;4;3\u{07}".utf8)) // omp active sequence
        XCTAssertEqual(t.evaluate(), .init(agent: "oh-my-pi", state: .working))
        t.noteOutput(Data("\u{1b}]9;4;0;\u{07}".utf8)) // omp clear sequence
        XCTAssertEqual(t.evaluate(), .init(agent: "oh-my-pi", state: .idle))
    }

    func testOutputActivityAloneIsNotWorking() {
        // Keystroke echo / chat scroll must NOT flip the state.
        let t = tracker()
        t.noteForegroundProcesses(names: ["claude"])
        t.noteTitle("Claude Code")
        t.noteOutput(Data("just some echoed typing and prose output\r\n".utf8))
        XCTAssertEqual(t.evaluate(), .init(agent: "claude-code", state: .idle))
    }

    func testCodexWorkingRequiresTimerShape() {
        let t = tracker()
        t.noteForegroundProcesses(names: ["codex"])
        t.noteOutput(Data("• Working (12s • esc to interrupt)\r\n".utf8))
        XCTAssertEqual(t.evaluate(), .init(agent: "codex", state: .working))

        // Prose merely mentioning the hint must not match.
        let t2 = tracker()
        t2.noteForegroundProcesses(names: ["codex"])
        t2.noteOutput(Data("the status bar says esc to interrupt somewhere\r\n".utf8))
        XCTAssertEqual(t2.evaluate(), .init(agent: "codex", state: .idle))
    }

    // MARK: - Blocked: narrow per-agent dialog shapes

    func testClaudeApprovalBlocks() {
        let t = tracker()
        t.noteForegroundProcesses(names: ["claude"])
        t.noteOutput(Data("""
        Do you want to proceed?
        \u{276f} 1. Yes
          2. Yes, and don't ask again
          3. No
        """.utf8))
        XCTAssertEqual(t.evaluate(), .init(agent: "claude-code", state: .blocked))
    }

    func testClaudeTrustDialogBlocks() {
        let t = tracker()
        t.noteForegroundProcesses(names: ["claude"])
        t.noteOutput(Data("\u{276f} 1. Yes, I trust this folder\r\n  2. No, exit\r\n".utf8))
        XCTAssertEqual(t.evaluate().state, .blocked)
    }

    func testCodexApprovalOutranksWorking() {
        let t = tracker()
        t.noteForegroundProcesses(names: ["codex"])
        t.noteOutput(Data("""
        Would you like to run the following command?
        \u{203a} 1. Yes, proceed (y)
        • Working (3s • esc to interrupt)
        """.utf8))
        XCTAssertEqual(t.evaluate(), .init(agent: "codex", state: .blocked))
    }

    func testOhMyPiPlanApprovalBlocks() {
        let t = tracker()
        t.noteForegroundProcesses(names: ["omp"])
        t.noteOutput(Data("Approve and execute\r\nApprove and keep context\r\n".utf8))
        XCTAssertEqual(t.evaluate(), .init(agent: "oh-my-pi", state: .blocked))
    }

    func testScreenClearDropsStaleDialog() {
        let t = tracker()
        t.noteForegroundProcesses(names: ["claude"])
        t.noteOutput(Data("\u{276f} 1. Yes\r\n".utf8))
        XCTAssertEqual(t.evaluate().state, .blocked)
        // Agent redraws a fresh screen (erase display) without the dialog.
        t.noteOutput(Data("\u{1b}[2Jsome new prompt\r\n".utf8))
        XCTAssertEqual(t.evaluate().state, .idle)
    }

    func testAltScreenEnterDropsStaleDialog() {
        let t = tracker()
        t.noteForegroundProcesses(names: ["claude"])
        t.noteOutput(Data("\u{276f} 1. Yes\r\n".utf8))
        XCTAssertEqual(t.evaluate().state, .blocked)
        // Agent opens a full-screen alt-buffer view (e.g. a pager): the main
        // screen's dialog is no longer visible.
        t.noteOutput(Data("\u{1b}[?1049hsome full screen view\r\n".utf8))
        XCTAssertEqual(t.evaluate().state, .idle)
    }

    func testAnsiIsStrippedBeforeScreenRules() {
        let t = tracker()
        t.noteForegroundProcesses(names: ["claude"])
        t.noteOutput(Data(
            "\u{1b}[36m\u{276f}\u{1b}[0m 1. \u{1b}[1mYes\u{1b}[0m".utf8
        ))
        XCTAssertEqual(t.evaluate().state, .blocked)
    }

    func testBellIsRecordedButOSCTerminatorIsNot() {
        let t = tracker()
        t.noteOutput(Data("ding\u{07}".utf8))
        XCTAssertNotNil(t.lastBell)
        let t2 = tracker()
        t2.noteOutput(Data("\u{1b}]0;title\u{07}".utf8))
        XCTAssertNil(t2.lastBell)
    }
}
