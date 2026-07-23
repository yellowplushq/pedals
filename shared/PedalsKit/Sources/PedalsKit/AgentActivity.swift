import CryptoKit
import Foundation

/// Rich coding-agent state embedded in the aggregate Pedals Live Activity.
///
/// The Worker receives only a server-visible state, timestamp, and opaque
/// ciphertext. Agent identity, project, prompt, action, and message remain
/// encrypted from the daemon to the widget extension. The payload is kept
/// deliberately small because ActivityKit caps ContentState at 4 KiB.
public enum AgentActivity {
    public enum Attention: String, Codable, CaseIterable, Sendable {
        case waiting
        case error
        case done
    }

    public struct Content: Codable, Equatable, Sendable {
        public var id: String
        public var agent: String
        public var state: AgentState
        public var project: String?
        public var prompt: String?
        public var action: String?
        public var message: String?
        public var sessionId: Int?
        public var terminal: String?
        public var updatedAt: Double

        public init(
            id: String,
            agent: String,
            state: AgentState,
            project: String? = nil,
            prompt: String? = nil,
            action: String? = nil,
            message: String? = nil,
            sessionId: Int? = nil,
            terminal: String? = nil,
            updatedAt: Double
        ) {
            self.id = id
            self.agent = agent
            self.state = state
            self.project = project
            self.prompt = prompt
            self.action = action
            self.message = message
            self.sessionId = sessionId
            self.terminal = terminal
            self.updatedAt = updatedAt
        }

        public init(info: AgentInfo) {
            self.init(
                id: info.id,
                agent: info.agent,
                state: info.state,
                project: Self.projectName(from: info.cwd),
                prompt: info.prompt.map { Self.singleLine($0, limit: 160) },
                action: info.action.map { Self.singleLine($0, limit: 100) },
                message: info.message.map { Self.singleLine($0, limit: 240) },
                sessionId: info.sessionId,
                terminal: info.term.map { Self.singleLine($0, limit: 40) },
                updatedAt: info.updatedAt
            )
        }

        private static func projectName(from path: String) -> String? {
            guard !path.isEmpty else { return nil }
            return singleLine((path as NSString).lastPathComponent, limit: 80)
        }

        private static func singleLine(_ value: String, limit: Int) -> String {
            let normalized = value
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
            var result = String(normalized.prefix(limit))
            while result.utf8.count > limit {
                result.removeLast()
            }
            return result
        }
    }

    /// A dedicated key means access granted to the widget extension never
    /// exposes either relay traffic direction or the pairing secret itself.
    public static func activityKey(secret: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secret),
            salt: KeyDerivation.salt,
            info: Data("live-activity".utf8),
            outputByteCount: KeyDerivation.keyByteCount
        )
    }

    public static func seal(
        _ content: Content, key: SymmetricKey, computerID: String
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let plaintext = try encoder.encode(content)
        let box = try ChaChaPoly.seal(
            plaintext, using: key, authenticating: Data(computerID.utf8)
        )
        return box.combined
    }

    public static func open(
        _ sealed: Data, key: SymmetricKey, computerID: String
    ) throws -> Content {
        let box = try ChaChaPoly.SealedBox(combined: sealed)
        let plaintext = try ChaChaPoly.open(
            box, using: key, authenticating: Data(computerID.utf8)
        )
        return try JSONDecoder().decode(Content.self, from: plaintext)
    }

    public static func displayName(forAgent slug: String) -> String {
        switch slug {
        case "claude": "Claude Code"
        case "codex": "Codex"
        case "copilot": "Copilot CLI"
        case "grok": "Grok"
        case "hermes": "Hermes"
        case "kimi": "Kimi Code"
        case "kiro": "Kiro"
        case "omp": "Oh My Pi"
        case "opencode": "OpenCode"
        case "pi": "Pi"
        default: slug.capitalized
        }
    }
}
