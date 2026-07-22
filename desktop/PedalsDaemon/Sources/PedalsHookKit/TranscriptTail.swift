import Foundation

/// What a Stop-time transcript scan learned about the just-ended turn.
public struct TranscriptSummary: Equatable, Sendable {
    /// Concatenated text of the last assistant message, capped and stripped.
    public var lastMessage: String?
    /// The turn died on an API error (no later user/assistant line followed).
    public var isError: Bool

    public init(lastMessage: String? = nil, isError: Bool = false) {
        self.lastMessage = lastMessage
        self.isError = isError
    }
}

/// Tail scan of a Claude Code transcript (JSONL). Only the last 256 KiB are
/// read; any parse failure degrades to no-message/no-error — the scan must
/// never invent a spurious error.
public enum TranscriptTail {
    public static let tailLimit = 256 * 1024

    public static func scan(path: String, sessionId: String) -> TranscriptSummary {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            return TranscriptSummary()
        }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return TranscriptSummary() }
        let start = size > UInt64(tailLimit) ? size - UInt64(tailLimit) : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd()
        else { return TranscriptSummary() }

        var lines = data.split(separator: UInt8(ascii: "\n"))
        // A mid-file start almost certainly landed inside a line; drop it.
        if start > 0, !lines.isEmpty { lines.removeFirst() }

        var lastMessage: String?
        var isError = false
        for line in lines {
            guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
            else { continue }
            let type = object["type"] as? String
            if (object["isApiErrorMessage"] as? Bool) == true {
                // A dead turn ends on the error line; a recovered turn has
                // later user/assistant traffic that clears the flag below.
                if object["sessionId"] as? String == sessionId { isError = true }
            } else if type == "user" || type == "assistant" {
                isError = false
            }
            if type == "assistant", let text = assistantText(object), !text.isEmpty {
                lastMessage = text
            }
        }
        return TranscriptSummary(lastMessage: lastMessage, isError: isError)
    }

    /// Concatenated `message.content[].text` parts of an assistant line.
    private static func assistantText(_ object: [String: Any]) -> String? {
        guard let message = object["message"] as? [String: Any],
              let content = message["content"] as? [Any]
        else { return nil }
        let text = content.compactMap { item -> String? in
            guard let part = item as? [String: Any],
                  part["type"] as? String == "text"
            else { return nil }
            return part["text"] as? String
        }.joined(separator: " ")
        let cleaned = sanitizeHookText(text, cap: HookFieldCaps.message)
        return cleaned.isEmpty ? nil : cleaned
    }
}
