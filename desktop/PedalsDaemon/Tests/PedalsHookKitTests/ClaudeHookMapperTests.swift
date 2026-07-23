import Foundation
import XCTest

@testable import PedalsHookKit

/// Claude hook stdin → stable event vocabulary mapping.
final class ClaudeHookMapperTests: XCTestCase {
    private func map(_ object: [String: Any]) -> HookReport? {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return ClaudeHookMapper.report(stdinData: data)
    }

    private func base(_ event: String) -> [String: Any] {
        ["hook_event_name": event, "session_id": "s-1", "cwd": "/tmp/project"]
    }

    func testEventMappingTable() {
        XCTAssertEqual(map(base("SessionStart"))?.event, "session-start")
        XCTAssertEqual(map(base("UserPromptSubmit"))?.event, "prompt")
        XCTAssertEqual(map(base("Notification"))?.event, "notify")
        XCTAssertEqual(map(base("PreCompact"))?.event, "compact")
        XCTAssertEqual(map(base("Stop"))?.event, "stop")
        XCTAssertEqual(map(base("SessionEnd"))?.event, "session-end")
        XCTAssertNil(map(base("SubagentStop")), "unknown events map to nil")
        XCTAssertNil(map(base("PostToolUse")), "unknown events map to nil")
    }

    func testSessionAndCwdCarried() {
        var object = base("SessionStart")
        object["session_name"] = "Pedals release"
        object["transcript_path"] = "/Users/test/.claude/projects/s-1.jsonl"
        let report = map(object)
        XCTAssertEqual(report?.agentSessionId, "s-1")
        XCTAssertEqual(report?.sessionName, "Pedals release")
        XCTAssertEqual(report?.cwd, "/tmp/project")
        XCTAssertEqual(
            report?.transcriptPath, "/Users/test/.claude/projects/s-1.jsonl"
        )
    }

    func testNotificationTitleIsNotMistakenForSessionName() {
        var object = base("Notification")
        object["title"] = "Agent needs attention"
        XCTAssertNil(map(object)?.sessionName)
    }

    func testPromptCarriedAndCapped() {
        var object = base("UserPromptSubmit")
        object["prompt"] = "fix the bug\nplease"
        XCTAssertEqual(map(object)?.prompt, "fix the bug please")

        object["prompt"] = String(repeating: "x", count: 500)
        XCTAssertEqual(map(object)?.prompt?.count, 200)
    }

    func testTranscriptPathIsCappedAndCarriedOnEveryEvent() {
        var object = base("PreToolUse")
        object["tool_name"] = "Bash"
        object["transcript_path"] = "/" + String(repeating: "p", count: 5000) + ".jsonl"
        XCTAssertEqual(map(object)?.transcriptPath?.count, 4096)
    }

    func testAskToolsMapToAsk() {
        for tool in ["AskUserQuestion", "ExitPlanMode"] {
            var object = base("PreToolUse")
            object["tool_name"] = tool
            let report = map(object)
            XCTAssertEqual(report?.event, "ask")
            XCTAssertNil(report?.action)
        }
    }

    func testToolActionFromCommandFirstLine() {
        var object = base("PreToolUse")
        object["tool_name"] = "Bash"
        object["tool_input"] = ["command": "git status\ngit diff"]
        XCTAssertEqual(map(object)?.action, "Bash: git status")
    }

    func testToolActionFromFilePathLastComponent() {
        var object = base("PreToolUse")
        object["tool_name"] = "Edit"
        object["tool_input"] = ["file_path": "/deep/path/to/Daemon.swift"]
        XCTAssertEqual(map(object)?.action, "Edit: Daemon.swift")
    }

    func testToolActionFromSearchPattern() {
        var object = base("PreToolUse")
        object["tool_name"] = "Glob"
        object["tool_input"] = ["pattern": "**/*.swift"]
        XCTAssertEqual(map(object)?.action, "Glob: **/*.swift")
    }

    func testToolActionCapped() {
        var object = base("PreToolUse")
        object["tool_name"] = "Bash"
        object["tool_input"] = ["command": String(repeating: "a", count: 500)]
        XCTAssertEqual(map(object)?.action?.count, 120)
    }

    func testNotifyMessageCarriedAndCapped() {
        var object = base("Notification")
        object["message"] = "Claude needs your permission to use Bash"
        XCTAssertEqual(map(object)?.message, "Claude needs your permission to use Bash")

        object["message"] = String(repeating: "m", count: 400)
        XCTAssertEqual(map(object)?.message?.count, 300)
    }

    func testStopWithoutTranscriptDegradesToNoError() {
        let report = map(base("Stop"))
        XCTAssertEqual(report?.event, "stop")
        XCTAssertEqual(report?.agentError, false)
        XCTAssertNil(report?.message)
    }

    func testMalformedStdin() {
        XCTAssertNil(ClaudeHookMapper.report(stdinData: Data("not json".utf8)))
        XCTAssertNil(ClaudeHookMapper.report(stdinData: Data()))
        XCTAssertNil(ClaudeHookMapper.report(stdinData: Data("[1,2,3]".utf8)))
        // Missing session id.
        XCTAssertNil(map(["hook_event_name": "SessionStart"]))
        // Empty session id.
        XCTAssertNil(map(["hook_event_name": "SessionStart", "session_id": ""]))
        // Missing event name.
        XCTAssertNil(map(["session_id": "s-1"]))
        // Wrongly typed fields must not crash.
        XCTAssertNil(map(["hook_event_name": 7, "session_id": "s-1"]))
    }

    func testControlCharactersStripped() {
        var object = base("Notification")
        object["message"] = "line1\u{07}\u{1B}[31mline2\u{7F}"
        let message = try! XCTUnwrap(map(object)?.message)
        XCTAssertFalse(message.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F })
    }
}
