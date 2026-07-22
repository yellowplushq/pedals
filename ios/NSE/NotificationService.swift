import CryptoKit
import PedalsKit
import UserNotifications

/// Rewrites the Worker's generic agent alert ("An agent needs your input")
/// with the E2EE content the daemon sealed: agent name, project, and the
/// actual message. Decryption is best-effort — any failure delivers the
/// generic text untouched, never nothing.
final class NotificationService: UNNotificationServiceExtension {
    private var pendingHandler: ((UNNotificationContent) -> Void)?
    private var pendingContent: UNMutableNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        pendingHandler = contentHandler
        pendingContent = content

        if let rewritten = Self.rewrite(content) {
            deliver(rewritten)
        } else {
            deliver(content)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        if let content = pendingContent {
            deliver(content)
        }
    }

    private func deliver(_ content: UNNotificationContent) {
        let handler = pendingHandler
        pendingHandler = nil
        pendingContent = nil
        handler?(content)
    }

    /// Returns nil when the push carries no sealed payload or it cannot be
    /// decrypted (missing key, tampered blob, unknown computer).
    private static func rewrite(
        _ content: UNMutableNotificationContent
    ) -> UNMutableNotificationContent? {
        guard let pedals = content.userInfo["pedals"] as? [String: Any],
              let computerID = pedals["computerId"] as? String,
              let sealedBase64 = pedals["sealed"] as? String,
              let sealed = Data(base64Encoded: sealedBase64),
              let keyData = AgentNotificationKeyStore.key(forComputer: computerID),
              let opened = try? AgentNotification.open(
                  sealed, key: SymmetricKey(data: keyData), computerID: computerID
              )
        else { return nil }

        let name = AgentNotification.displayName(forAgent: opened.agent)
        // The generic title is the host name; it survives in the subtitle
        // next to the project so multi-computer users keep the context.
        let hostName = content.title == "Pedals" ? nil : content.title
        switch opened.category {
        case .waiting:
            content.title = "\(name) needs you"
        case .error:
            content.title = "\(name) hit an error"
        case .done:
            content.title = "\(name) finished"
        }
        let project = opened.cwd.flatMap { cwd -> String? in
            cwd.isEmpty ? nil : (cwd as NSString).lastPathComponent
        }
        content.subtitle = [project, hostName].compactMap { $0 }.joined(separator: " · ")
        if let message = opened.message, !message.isEmpty {
            content.body = message
        }
        return content
    }
}
