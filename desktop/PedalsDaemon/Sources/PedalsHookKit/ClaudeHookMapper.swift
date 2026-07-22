import Foundation

/// Maps a Claude Code hook invocation (its stdin JSON) onto the daemon's
/// stable event vocabulary. The per-agent adapter is deliberately thin: this
/// mapping is the only Claude-specific knowledge in the reporter
/// (docs/AGENT_MONITORING_DESIGN.md §3).
public enum ClaudeHookMapper {
    /// PreToolUse tools that mean "the agent is waiting for the user".
    static let askTools: Set<String> = ["AskUserQuestion", "ExitPlanMode"]

    /// Parses hook stdin JSON and maps the event. Returns nil for unknown or
    /// malformed events; the reporter then exits silently.
    public static func report(stdinData: Data) -> HookReport? {
        guard
            let object = (try? JSONSerialization.jsonObject(with: stdinData)) as? [String: Any],
            let eventName = object["hook_event_name"] as? String,
            let sessionId = object["session_id"] as? String, !sessionId.isEmpty
        else { return nil }

        var report = HookReport(
            event: "", agentSessionId: sessionId, cwd: object["cwd"] as? String
        )
        switch eventName {
        case "SessionStart":
            report.event = "session-start"
        case "UserPromptSubmit":
            report.event = "prompt"
            report.prompt = (object["prompt"] as? String).map {
                sanitizeHookText($0, cap: HookFieldCaps.prompt)
            }
        case "PreToolUse":
            let tool = object["tool_name"] as? String ?? ""
            if askTools.contains(tool) {
                report.event = "ask"
            } else {
                report.event = "tool"
                let line = hookActionLine(tool: tool, input: object["tool_input"] as? [String: Any])
                report.action = sanitizeHookText(line, cap: HookFieldCaps.action)
            }
        case "Notification":
            report.event = "notify"
            report.message = (object["message"] as? String).map {
                sanitizeHookText($0, cap: HookFieldCaps.message)
            }
        case "PreCompact":
            report.event = "compact"
        case "Stop":
            report.event = "stop"
            if let path = object["transcript_path"] as? String, !path.isEmpty {
                let summary = TranscriptTail.scan(path: path, sessionId: sessionId)
                report.message = summary.lastMessage
                report.agentError = summary.isError
            } else {
                report.agentError = false
            }
        case "SessionEnd":
            report.event = "session-end"
        default:
            return nil
        }
        return report
    }
}
