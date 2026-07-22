import Foundation

/// GitHub Copilot CLI: a whole file Pedals owns at
/// `~/.copilot/hooks/pedals.json` — Copilot merges every JSON file in that
/// directory, so no merge with user content is needed. Note the Copilot
/// entry keys: `bash` (not `command`) and `timeoutSec`.
extension HookInstaller {
    enum Copilot {
        static func path(home: URL) -> String {
            home.appendingPathComponent(".copilot", isDirectory: true)
                .appendingPathComponent("hooks", isDirectory: true)
                .appendingPathComponent("pedals.json").path
        }

        /// (copilot event, reporter event, timeoutSec). Copilot alone has a
        /// distinct `notification` reporter event.
        static let events: [(event: String, reporterEvent: String, timeout: Int)] = [
            ("sessionStart", "session-start", 5),
            ("userPromptSubmitted", "prompt", 10),
            ("preToolUse", "tool", 5),
            ("postToolUse", "busy", 5),
            ("agentStop", "stop", 10),
            ("sessionEnd", "session-end", 5),
            ("notification", "notification", 10),
        ]

        static func canonicalData(reporterPath: String) -> Data {
            var hooks: [String: Any] = [:]
            for (event, reporterEvent, timeout) in events {
                hooks[event] = [
                    [
                        "type": "command",
                        "bash": reporterCommand(reporterPath, slug: "copilot", event: reporterEvent),
                        "timeoutSec": timeout,
                    ] as [String: Any]
                ]
            }
            let root: [String: Any] = ["version": 1, "hooks": hooks]
            var data = (try? serializeSettings(root)) ?? Data()
            data.append(0x0A)
            return data
        }

        static func install(reporterPath: String, home: URL) throws {
            try OwnedFile.install(
                canonical: canonicalData(reporterPath: reporterPath),
                path: path(home: home), marker: sentinel
            )
        }

        static func uninstall(home: URL) throws {
            try OwnedFile.uninstall(path: path(home: home), marker: sentinel)
        }

        static func state(reporterPath: String, home: URL) -> State {
            OwnedFile.state(
                canonical: canonicalData(reporterPath: reporterPath),
                path: path(home: home), marker: sentinel
            )
        }
    }
}
