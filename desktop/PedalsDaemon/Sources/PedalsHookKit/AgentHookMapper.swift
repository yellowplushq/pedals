import Darwin
import Foundation

/// Optional enrichment fields parsed from the stdin of Claude-hook-compatible
/// CLIs (codex, copilot, grok, kimi, kiro). The payload shape mirrors Claude
/// Code's flat hook JSON; every field is untrusted and optional — the argv
/// `--event` alone decides the mapped event.
struct ClaudeFlatStdin {
    var sessionId: String?
    var cwd: String?
    var prompt: String?
    var toolName: String?
    /// "ToolName: detail" one-liner from `tool_name` + `tool_input`, capped.
    var action: String?
    /// First non-empty of `message`, `last_assistant_message`,
    /// `assistant_response` (supacode's precedence), capped.
    var message: String?

    init(data: Data) {
        self.init(object: (try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
    }

    init(object: [String: Any]?) {
        guard let object else { return }
        if let id = object["session_id"] as? String, !id.isEmpty {
            sessionId = id
        }
        cwd = object["cwd"] as? String
        if let prompt = object["prompt"] as? String {
            let cleaned = sanitizeHookText(prompt, cap: HookFieldCaps.prompt)
            if !cleaned.isEmpty { self.prompt = cleaned }
        }
        if let tool = object["tool_name"] as? String, !tool.isEmpty {
            toolName = tool
            let line = hookActionLine(tool: tool, input: object["tool_input"] as? [String: Any])
            action = sanitizeHookText(line, cap: HookFieldCaps.action)
        }
        for key in ["message", "last_assistant_message", "assistant_response"] {
            guard let value = object[key] as? String else { continue }
            let cleaned = sanitizeHookText(value, cap: HookFieldCaps.message)
            if !cleaned.isEmpty {
                message = cleaned
                break
            }
        }
    }
}

/// Optional enrichment fields composed by OUR generated plugins (opencode,
/// omp, pi, hermes): flat JSON with camelCase keys. Untrusted like everything
/// else on stdin.
struct NormalizedStdin {
    var sessionId: String?
    var cwd: String?
    var message: String?
    var action: String?

    init(data: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return }
        if let id = object["sessionId"] as? String, !id.isEmpty {
            sessionId = id
        }
        cwd = object["cwd"] as? String
        if let message = object["message"] as? String {
            let cleaned = sanitizeHookText(message, cap: HookFieldCaps.message)
            if !cleaned.isEmpty { self.message = cleaned }
        }
        if let action = object["action"] as? String {
            let cleaned = sanitizeHookText(action, cap: HookFieldCaps.action)
            if !cleaned.isEmpty { self.action = cleaned }
        }
    }
}

/// Maps a non-Claude agent hook invocation (`pedals-hook <slug> --event
/// <event>` plus optional stdin enrichment) onto the stable event vocabulary.
/// Unlike Claude, these agents name the event on argv — stdin only enriches.
/// Returns nil for unknown slugs/events; the reporter then exits silently.
public enum AgentHookMapper {
    /// Claude-hook-compatible-ish CLIs: stdin (when present) is flat
    /// Claude-shaped JSON.
    static let claudeFlatSlugs: Set<String> = ["codex", "copilot", "grok", "kimi", "kiro"]
    /// Agents driven by our generated plugins, which compose NormalizedStdin.
    static let normalizedSlugs: Set<String> = ["opencode", "omp", "pi", "hermes"]

    /// Every slug this mapper handles (`claude` is handled by
    /// ClaudeHookMapper and is not in this set).
    public static var slugs: Set<String> { claudeFlatSlugs.union(normalizedSlugs) }

    /// Wire vocabulary accepted on argv for the Claude-flat family.
    static let genericEvents: Set<String> = [
        "session-start", "prompt", "tool", "busy", "ask", "notify", "stop",
        "session-end",
    ]
    /// Our plugins emit turn starts as `busy` and never `prompt` (they have
    /// no prompt text source).
    static let normalizedEvents: Set<String> = [
        "session-start", "busy", "tool", "ask", "notify", "stop", "session-end",
    ]

    /// Copilot's notification hook only means "waiting for the user" for
    /// these payload types (supacode gates on exactly these two).
    static let copilotNotifyGates = ["permission_prompt", "elicitation_dialog"]

    public static func report(
        slug: String, event: String, stdinData: Data,
        fallbackSessionId: String? = nil
    ) -> HookReport? {
        // Deterministic per agent process, so repeated events without a
        // stdin session id coalesce into one record.
        let fallback = fallbackSessionId ?? "\(slug)-\(getppid())"
        if claudeFlatSlugs.contains(slug) {
            if slug == "copilot", event == "notification" {
                return copilotNotification(stdinData: stdinData, fallbackSessionId: fallback)
            }
            guard genericEvents.contains(event) else { return nil }
            return genericReport(
                event: event, stdin: ClaudeFlatStdin(data: stdinData),
                fallbackSessionId: fallback
            )
        }
        if normalizedSlugs.contains(slug) {
            guard normalizedEvents.contains(event) else { return nil }
            return normalizedReport(
                event: event, stdin: NormalizedStdin(data: stdinData),
                fallbackSessionId: fallback
            )
        }
        return nil
    }

    /// Generic argv-event path: the event passes through as-is; stdin only
    /// fills the fields that event carries. No transcript probe and no
    /// `agentError` for these agents.
    static func genericReport(
        event: String, stdin: ClaudeFlatStdin, fallbackSessionId: String
    ) -> HookReport? {
        var report = HookReport(
            event: event, agentSessionId: stdin.sessionId ?? fallbackSessionId,
            cwd: stdin.cwd
        )
        switch event {
        case "prompt":
            report.prompt = stdin.prompt
        case "tool":
            // Mirror the Claude mapper: an ask-shaped tool means "waiting".
            if let tool = stdin.toolName, ClaudeHookMapper.askTools.contains(tool) {
                report.event = "ask"
            } else {
                report.action = stdin.action
            }
        case "notify", "stop":
            report.message = stdin.message
        default:
            // session-start, busy, ask, session-end carry no text; `busy`
            // in particular must not clear or set prompt/action downstream.
            break
        }
        return report
    }

    /// Copilot `--event notification`: only permission prompts and
    /// elicitation dialogs mean "waiting for the user"; everything else
    /// (welcome toasts, update notes, …) is dropped.
    static func copilotNotification(
        stdinData: Data, fallbackSessionId: String
    ) -> HookReport? {
        let raw = String(decoding: stdinData, as: UTF8.self)
        let object = (try? JSONSerialization.jsonObject(with: stdinData)) as? [String: Any]
        let type = object?["type"] as? String ?? ""
        guard copilotNotifyGates.contains(where: { raw.contains($0) || type.contains($0) })
        else { return nil }
        let stdin = ClaudeFlatStdin(object: object)
        return HookReport(
            event: "notify", agentSessionId: stdin.sessionId ?? fallbackSessionId,
            cwd: stdin.cwd, message: stdin.message
        )
    }

    /// Normalized-plugin path: fields pass through as provided (per event).
    static func normalizedReport(
        event: String, stdin: NormalizedStdin, fallbackSessionId: String
    ) -> HookReport? {
        var report = HookReport(
            event: event, agentSessionId: stdin.sessionId ?? fallbackSessionId,
            cwd: stdin.cwd
        )
        switch event {
        case "tool":
            report.action = stdin.action
        case "ask", "notify", "stop":
            report.message = stdin.message
        default:
            break // session-start, busy, session-end carry no text
        }
        return report
    }
}
