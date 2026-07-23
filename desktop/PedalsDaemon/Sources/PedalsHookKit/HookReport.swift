import Foundation

/// One mapped hook event, ready for wire encoding (PROTOCOL.md §7
/// `agent-event`). Field caps are applied here and re-applied by the daemon:
/// both ends defend independently.
public struct HookReport: Equatable, Sendable {
    /// Stable event vocabulary: `session-start`, `prompt`, `ask`, `tool`,
    /// `busy`, `notify`, `compact`, `stop`, `session-end`.
    public var event: String
    /// The agent's own session id (Claude Code `session_id`).
    public var agentSessionId: String
    /// Optional user-facing name supplied by the agent hook.
    public var sessionName: String?
    public var cwd: String?
    /// The user's prompt text (`prompt` events only), capped.
    public var prompt: String?
    /// The agent's last message (`notify`/`stop`), capped.
    public var message: String?
    /// One-line current action (`tool` events only), capped.
    public var action: String?
    /// `stop` only: the turn ended on an agent-side failure (API error).
    public var agentError: Bool?

    public init(
        event: String, agentSessionId: String, sessionName: String? = nil,
        cwd: String? = nil,
        prompt: String? = nil, message: String? = nil, action: String? = nil,
        agentError: Bool? = nil
    ) {
        self.event = event
        self.agentSessionId = agentSessionId
        self.sessionName = sessionName
        self.cwd = cwd
        self.prompt = prompt
        self.message = message
        self.action = action
        self.agentError = agentError
    }
}

/// Shared field caps, applied by every mapper; the daemon re-applies the same
/// caps on ingest.
enum HookFieldCaps {
    static let prompt = 200
    static let action = 120
    static let message = 300
    static let sessionName = 120
}

/// Session-name fields used by agent hook payloads. A generic notification
/// `title` is intentionally excluded: it describes the event, not the
/// persistent session identity.
func hookSessionName(from object: [String: Any]) -> String? {
    for key in ["session_name", "session_title", "sessionName", "sessionTitle"] {
        guard let value = object[key] as? String else { continue }
        let cleaned = sanitizeHookText(value, cap: HookFieldCaps.sessionName)
        if !cleaned.isEmpty { return cleaned }
    }
    return nil
}

/// "ToolName: detail" one-liner shared by all Claude-shaped mappers: detail is
/// the first line of `tool_input.command`, else the last path component of
/// `tool_input.file_path`, else empty.
func hookActionLine(tool: String, input: [String: Any]?) -> String {
    var detail = ""
    if let command = input?["command"] as? String {
        detail = command
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first.map(String.init) ?? ""
    } else if let path = input?["file_path"] as? String, !path.isEmpty {
        detail = (path as NSString).lastPathComponent
    }
    detail = detail.trimmingCharacters(in: .whitespaces)
    if tool.isEmpty { return detail }
    return detail.isEmpty ? tool : "\(tool): \(detail)"
}

/// Shared field hygiene: strips C0 controls (and DEL) and caps length. The
/// daemon applies the same treatment again on ingest.
func sanitizeHookText(_ value: String, cap: Int) -> String {
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
