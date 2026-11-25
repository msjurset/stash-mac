import Foundation

/// Sends macOS desktop notifications using the same pattern as `sortie`
/// and `gostash`: prefers `terminal-notifier` when a clickable `link` is
/// supplied, and falls back to macOS's built-in `osascript` `display
/// notification` command so notifications always appear reliably regardless
/// of bundle code-signing or foreground activation state.
enum DesktopNotifier {
    struct NotificationRecord: Equatable, Sendable {
        let title: String
        let message: String
        let link: String?
    }

    /// Optional hook used by unit tests to capture notifications without
    /// spawning `osascript` or `terminal-notifier` during test runs.
    nonisolated(unsafe) static var testObserver: ((NotificationRecord) -> Void)?

    /// Escapes a string for safe interpolation inside an AppleScript double-quoted literal.
    static func appleScriptQuote(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return "\"\(escaped)\""
    }

    /// Builds the `osascript -e` script string for a title and message.
    static func buildAppleScript(title: String, message: String) -> String {
        "display notification \(appleScriptQuote(message)) with title \(appleScriptQuote(title))"
    }

    /// Resolves `terminal-notifier` if installed on the system.
    static func findTerminalNotifier() -> String? {
        let candidates = [
            "/opt/homebrew/bin/terminal-notifier",
            "/usr/local/bin/terminal-notifier"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    /// Fires a non-blocking macOS desktop notification.
    static func notify(title: String, message: String, link: String? = nil) {
        if let observer = testObserver {
            observer(NotificationRecord(title: title, message: message, link: link))
            return
        }
        Task.detached(priority: .utility) {
            notifySync(title: title, message: message, link: link)
        }
    }

    /// Synchronous helper used by background tasks and unit tests.
    @discardableResult
    static func notifySync(title: String, message: String, link: String? = nil) -> Bool {
        if let link, !link.isEmpty, let notifierPath = findTerminalNotifier() {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: notifierPath)
            proc.arguments = ["-title", title, "-message", message, "-open", link]
            proc.standardOutput = Pipe()
            proc.standardError = Pipe()
            do {
                try proc.run()
                proc.waitUntilExit()
                if proc.terminationStatus == 0 {
                    return true
                }
            } catch {
                // Fall through to osascript
            }
        }

        let script = buildAppleScript(title: title, message: message)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }
}
