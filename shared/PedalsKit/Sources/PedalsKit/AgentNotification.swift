import CryptoKit
import Foundation

/// An agent notification: daemon → Worker → APNs, emitted purely to drive
/// Apple push notifications when an agent transitions to a state that
/// involves the user (blocked/error/finished).
///
/// Privacy split (docs/AGENT_MONITORING_DESIGN.md §6): the Worker sees only
/// the category, the daemon session id, and an opaque sealed blob. The rich
/// content (agent name, message, project) travels inside `sealed`, encrypted
/// under a key derived from the computer secret that only the paired phone
/// holds. The Notification Service Extension decrypts it on-device and
/// rewrites the generic text; without the NSE the generic text shows.
public enum AgentNotification {
    /// Server-visible update category. Maps 1:1 to the generic (non-rich)
    /// notification body the Worker composes.
    public enum Category: String, Codable, CaseIterable, Sendable {
        case waiting
        case error
        case done
    }

    /// The E2EE payload inside `sealed`. All fields are optional-tolerant on
    /// decode so daemon and app can rev independently.
    public struct Content: Codable, Equatable, Sendable {
        /// Agent kind slug: "claude", "codex", …
        public var agent: String
        public var category: Category
        /// The agent's message (ask prompt / last assistant message),
        /// truncated by the daemon before sealing.
        public var message: String?
        /// Project path (the agent's cwd), for the notification subtitle.
        public var cwd: String?
        /// Daemon session id when managed; drives the tap deep-link.
        public var sessionId: Int?

        public init(agent: String, category: Category, message: String? = nil,
                    cwd: String? = nil, sessionId: Int? = nil) {
            self.agent = agent
            self.category = category
            self.message = message
            self.cwd = cwd
            self.sessionId = sessionId
        }
    }

    /// Byte budgets for sealed content, mirroring the hook reporter's own
    /// truncation (supacode caps notify bodies at 1000 bytes).
    public static let messageByteBudget = 1000

    /// Key for sealing update content: derived from the computer secret with a
    /// dedicated info string so a leaked notification key (the NSE holds it)
    /// never exposes the relay traffic keys.
    public static func notificationKey(secret: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secret),
            salt: KeyDerivation.salt,
            info: Data("notification".utf8),
            outputByteCount: KeyDerivation.keyByteCount
        )
    }

    /// Seal content for the given computer. AAD binds the ciphertext to the
    /// computer id so the (untrusted) Worker cannot replay one computer's
    /// update under another computer's push.
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

    /// Human display name for an agent slug, shared by the Home screen and
    /// the Notification Service Extension.
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
        default: slug
        }
    }
}
