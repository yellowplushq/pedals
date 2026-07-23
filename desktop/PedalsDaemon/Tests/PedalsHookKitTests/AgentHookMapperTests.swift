import Darwin
import Foundation
import XCTest

@testable import PedalsHookKit

/// Non-Claude adapters: argv `--event` + optional stdin enrichment → stable
/// event vocabulary.
final class AgentHookMapperTests: XCTestCase {
    private func map(
        _ slug: String, _ event: String, _ object: [String: Any]? = nil,
        fallback: String = "fb-1"
    ) -> HookReport? {
        let data = object.map { try! JSONSerialization.data(withJSONObject: $0) } ?? Data()
        return AgentHookMapper.report(
            slug: slug, event: event, stdinData: data, fallbackSessionId: fallback
        )
    }

    private func flatBase(_ extra: [String: Any] = [:]) -> [String: Any] {
        var object: [String: Any] = ["session_id": "s-1", "cwd": "/tmp/project"]
        object.merge(extra) { _, new in new }
        return object
    }

    // MARK: - Generic (Claude-flat) family

    func testGenericEventPassThrough() {
        for slug in ["codex", "kimi", "grok", "kiro", "copilot"] {
            for event in [
                "session-start", "prompt", "tool", "busy", "ask", "notify",
                "stop", "session-end",
            ] {
                let report = map(slug, event, flatBase())
                XCTAssertEqual(report?.event, event, "\(slug) \(event)")
                XCTAssertEqual(report?.agentSessionId, "s-1")
                XCTAssertEqual(report?.cwd, "/tmp/project")
            }
        }
    }

    func testUnknownEventAndSlugMapToNil() {
        XCTAssertNil(map("codex", "compact", flatBase()), "compact is Claude-only")
        XCTAssertNil(map("codex", "frobnicate", flatBase()))
        XCTAssertNil(map("codex", "", flatBase()))
        XCTAssertNil(map("claude", "prompt", flatBase()), "claude is not argv-driven")
        XCTAssertNil(map("unknown-agent", "prompt", flatBase()))
        XCTAssertNil(
            map("codex", "notification", flatBase(["type": "permission_prompt"])),
            "notification is copilot-only"
        )
    }

    func testPromptOnlyCarriedOnPromptEvent() {
        let payload = flatBase(["prompt": "fix the bug\nplease"])
        XCTAssertEqual(map("codex", "prompt", payload)?.prompt, "fix the bug please")
        XCTAssertNil(map("codex", "tool", payload)?.prompt)
        XCTAssertNil(map("codex", "busy", payload)?.prompt)

        let long = flatBase(["prompt": String(repeating: "x", count: 500)])
        XCTAssertEqual(map("kimi", "prompt", long)?.prompt?.count, 200)
    }

    func testToolActionFromToolInput() {
        let command = flatBase([
            "tool_name": "Bash", "tool_input": ["command": "git status\ngit diff"],
        ])
        XCTAssertEqual(map("codex", "tool", command)?.action, "Bash: git status")

        let file = flatBase([
            "tool_name": "Edit", "tool_input": ["file_path": "/deep/path/Daemon.swift"],
        ])
        XCTAssertEqual(map("grok", "tool", file)?.action, "Edit: Daemon.swift")

        let bare = flatBase(["tool_name": "Glob"])
        XCTAssertEqual(map("kiro", "tool", bare)?.action, "Glob")

        let capped = flatBase([
            "tool_name": "Bash",
            "tool_input": ["command": String(repeating: "a", count: 500)],
        ])
        XCTAssertEqual(map("codex", "tool", capped)?.action?.count, 120)
    }

    func testAskToolsUpgradeToolEventToAsk() {
        for tool in ["AskUserQuestion", "ExitPlanMode"] {
            let report = map("codex", "tool", flatBase(["tool_name": tool]))
            XCTAssertEqual(report?.event, "ask")
            XCTAssertNil(report?.action)
        }
        // Only the `tool` event upgrades; a plain busy with that tool doesn't.
        XCTAssertEqual(
            map("codex", "busy", flatBase(["tool_name": "AskUserQuestion"]))?.event, "busy"
        )
    }

    func testBusyCarriesNoText() {
        let report = map("codex", "busy", flatBase([
            "prompt": "p", "tool_name": "Bash",
            "tool_input": ["command": "ls"], "message": "m",
        ]))
        XCTAssertEqual(report?.event, "busy")
        XCTAssertNil(report?.prompt)
        XCTAssertNil(report?.action)
        XCTAssertNil(report?.message)
    }

    func testMessagePrecedence() {
        let all = flatBase([
            "message": "primary",
            "last_assistant_message": "secondary",
            "assistant_response": "tertiary",
        ])
        XCTAssertEqual(map("codex", "stop", all)?.message, "primary")

        let emptyFirst = flatBase([
            "message": "   ",
            "last_assistant_message": "secondary",
            "assistant_response": "tertiary",
        ])
        XCTAssertEqual(
            map("codex", "notify", emptyFirst)?.message, "secondary",
            "empty message falls through to last_assistant_message"
        )

        let lastOnly = flatBase(["assistant_response": "tertiary"])
        XCTAssertEqual(map("codex", "stop", lastOnly)?.message, "tertiary")

        let capped = flatBase(["message": String(repeating: "m", count: 400)])
        XCTAssertEqual(map("codex", "stop", capped)?.message?.count, 300)

        // Message only rides notify/stop.
        XCTAssertNil(map("codex", "tool", all)?.message)
        XCTAssertNil(map("codex", "session-start", all)?.message)
    }

    func testGenericStopHasNoAgentError() {
        XCTAssertNil(map("codex", "stop", flatBase())?.agentError)
    }

    func testSessionIdFallback() {
        // Stdin session id wins.
        XCTAssertEqual(map("codex", "busy", flatBase())?.agentSessionId, "s-1")
        // No stdin / no session id → caller-provided fallback.
        XCTAssertEqual(map("codex", "busy", nil)?.agentSessionId, "fb-1")
        XCTAssertEqual(map("codex", "busy", ["session_id": ""])?.agentSessionId, "fb-1")
        // Default fallback shape: "<slug>-<ppid>".
        let report = AgentHookMapper.report(
            slug: "kimi", event: "busy", stdinData: Data("{}".utf8)
        )
        XCTAssertEqual(report?.agentSessionId, "kimi-\(getppid())")
    }

    func testSessionNameEnrichment() {
        XCTAssertEqual(
            map("codex", "busy", flatBase(["session_title": "Release prep"]))?.sessionName,
            "Release prep"
        )
        XCTAssertEqual(
            map("pi", "busy", ["sessionId": "n-1", "sessionName": "API cleanup"])?.sessionName,
            "API cleanup"
        )
        XCTAssertNil(
            map("codex", "notify", flatBase(["title": "Agent completed"]))?.sessionName,
            "event titles are not persistent session names"
        )
    }

    func testMalformedStdinStillReports() {
        // Argv names the event; garbage stdin degrades to no enrichment.
        let report = AgentHookMapper.report(
            slug: "codex", event: "busy", stdinData: Data("not json".utf8),
            fallbackSessionId: "fb-9"
        )
        XCTAssertEqual(report?.event, "busy")
        XCTAssertEqual(report?.agentSessionId, "fb-9")
        XCTAssertNil(report?.cwd)
    }

    func testControlCharactersStripped() {
        let payload = flatBase(["message": "line1\u{07}\u{1B}[31mline2\u{7F}"])
        let message = map("codex", "notify", payload)?.message
        XCTAssertNotNil(message)
        XCTAssertFalse(
            message!.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
        )
    }

    // MARK: - Copilot notification gate

    func testCopilotNotificationGatedOnPermissionPrompt() {
        let report = map("copilot", "notification", flatBase([
            "type": "permission_prompt", "message": "Allow Bash?",
        ]))
        XCTAssertEqual(report?.event, "notify")
        XCTAssertEqual(report?.agentSessionId, "s-1")
        XCTAssertEqual(report?.cwd, "/tmp/project")
        XCTAssertEqual(report?.message, "Allow Bash?")
    }

    func testCopilotNotificationGatedOnElicitationDialog() {
        let report = map("copilot", "notification", flatBase([
            "type": "elicitation_dialog", "last_assistant_message": "Pick one",
        ]))
        XCTAssertEqual(report?.event, "notify")
        XCTAssertEqual(report?.message, "Pick one")
    }

    func testCopilotNotificationRawSubstringHit() {
        // No `type` field, but the raw payload mentions the gate substring.
        let report = map("copilot", "notification", flatBase([
            "kind": "tool_permission_prompt_v2",
        ]))
        XCTAssertEqual(report?.event, "notify")
    }

    func testCopilotNotificationOtherTypeDropped() {
        XCTAssertNil(map("copilot", "notification", flatBase(["type": "welcome"])))
        XCTAssertNil(map("copilot", "notification", flatBase(["message": "hi"])))
        XCTAssertNil(map("copilot", "notification", nil))
    }

    // MARK: - Normalized family

    func testNormalizedFields() {
        for slug in ["opencode", "omp", "pi", "hermes"] {
            let ask = map(slug, "ask", [
                "sessionId": "n-1", "cwd": "/tmp/n", "message": "Approve?",
            ])
            XCTAssertEqual(ask?.event, "ask", slug)
            XCTAssertEqual(ask?.agentSessionId, "n-1")
            XCTAssertEqual(ask?.cwd, "/tmp/n")
            XCTAssertEqual(ask?.message, "Approve?")

            let tool = map(slug, "tool", ["sessionId": "n-1", "action": "Bash: ls"])
            XCTAssertEqual(tool?.action, "Bash: ls")
            XCTAssertNil(tool?.message)

            let stop = map(slug, "stop", ["sessionId": "n-1", "message": "Done."])
            XCTAssertEqual(stop?.message, "Done.")
            XCTAssertNil(stop?.agentError)
        }
    }

    func testNormalizedEventSet() {
        for event in ["session-start", "busy", "tool", "ask", "notify", "stop", "session-end"] {
            XCTAssertEqual(map("hermes", event, ["sessionId": "n-1"])?.event, event)
        }
        XCTAssertNil(map("opencode", "prompt", ["sessionId": "n-1"]), "no prompt source")
        XCTAssertNil(map("pi", "notification", ["sessionId": "n-1"]))
        XCTAssertNil(map("omp", "compact", ["sessionId": "n-1"]))
    }

    func testNormalizedBusyCarriesNoText() {
        let report = map("omp", "busy", [
            "sessionId": "n-1", "message": "m", "action": "a",
        ])
        XCTAssertEqual(report?.event, "busy")
        XCTAssertNil(report?.message)
        XCTAssertNil(report?.action)
    }

    func testNormalizedCapsAndFallback() {
        let report = map("pi", "notify", [
            "message": String(repeating: "m", count: 400)
        ])
        XCTAssertEqual(report?.agentSessionId, "fb-1")
        XCTAssertEqual(report?.message?.count, 300)

        let action = map("pi", "tool", ["action": String(repeating: "a", count: 500)])
        XCTAssertEqual(action?.action?.count, 120)

        // Claude-flat keys are not read by the normalized parser.
        let wrongKeys = map("pi", "notify", ["session_id": "s-1", "message": "hi"])
        XCTAssertEqual(wrongKeys?.agentSessionId, "fb-1")
    }
}
