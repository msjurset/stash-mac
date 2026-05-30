import AppKit
import UserNotifications

extension Notification.Name {
    static let stashDidIngest = Notification.Name("StashDidIngest")
}

final class ServicesProvider: NSObject {
    private let logFile = "/tmp/stash-services.log"

    @objc func stashSelection(
        _ pboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        performStash(pboard: pboard, tags: [], error: error)
    }

    @objc func readLater(
        _ pboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        performStash(pboard: pboard, tags: ["read-later"], error: error)
    }

    @objc func watchLater(
        _ pboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        performStash(pboard: pboard, tags: ["watch-later"], error: error)
    }

    private func performStash(
        pboard: NSPasteboard,
        tags: [String],
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        let label = tags.isEmpty ? "stashSelection" : tags.joined(separator: ", ")
        log("--- \(label) called ---")
        let frontApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Unknown"

        if let urls = pboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            let webURLs = urls.filter { $0.scheme?.hasPrefix("http") == true }
            if !webURLs.isEmpty {
                log("Got \(webURLs.count) web URL(s)")
                stashURLs(webURLs.map { $0.absoluteString }, tags: tags)
                return
            }
            
            let fileURLs = urls.filter { $0.isFileURL }
            if !fileURLs.isEmpty {
                log("Got \(fileURLs.count) file URL(s)")
                stashFiles(fileURLs.map { $0.path }, tags: tags)
                return
            }
        }

        if let text = pboard.string(forType: .string), !text.isEmpty {
            log("Got text (\(text.count) chars)")
            stashText(text, from: frontApp, tags: tags)
            return
        }

        log("No usable text or file URLs on pasteboard")
        let msg: NSString = "Nothing to stash — selection was empty."
        error.pointee = msg
        notify(title: "Stash", body: msg as String)
    }

    private func stashText(_ text: String, from appName: String, tags: [String]) {
        let op: @Sendable () async -> Void = {
            await Self.performStashText(text: text, appName: appName, tags: tags)
        }
        Task.detached(operation: op)
    }

    private func stashFiles(_ paths: [String], tags: [String]) {
        let op: @Sendable () async -> Void = {
            await Self.performStashFiles(paths: paths, tags: tags)
        }
        Task.detached(operation: op)
    }

    private func stashURLs(_ urls: [String], tags: [String]) {
        let op: @Sendable () async -> Void = {
            await Self.performStashURLs(urls: urls, tags: tags)
        }
        Task.detached(operation: op)
    }

    private static func performStashText(text: String, appName: String, tags: [String]) async {
        let title = "\(appName) (selection)"
        do {
            _ = try await StashCLI.shared.addSnippet(text: text, title: title, tags: tags)
            let body = tags.isEmpty ? "Selection from \(appName)" : "Added to \(tags.joined(separator: ", "))"
            notify(title: "Stashed", body: body)
            appendLog("Stashed snippet from \(appName)")
            await postIngestNotification()
        } catch {
            notify(title: "Stash failed", body: error.localizedDescription)
            appendLog("CLI error: \(error.localizedDescription)")
        }
    }

    private static func performStashFiles(paths: [String], tags: [String]) async {
        var successes = 0
        var failures: [String] = []
        for path in paths {
            do {
                _ = try await StashCLI.shared.addFile(path: path, tags: tags)
                successes += 1
            } catch {
                let name = (path as NSString).lastPathComponent
                failures.append("\(name): \(error.localizedDescription)")
            }
        }
        if successes > 0 {
            let body = successes == 1
                ? "1 file added to your stash."
                : "\(successes) files added to your stash."
            notify(title: "Stashed", body: body)
            appendLog("Stashed \(successes) file(s)")
            await postIngestNotification()
        }
        if !failures.isEmpty {
            notify(
                title: "Stash failed",
                body: failures.joined(separator: "; ")
            )
            appendLog("CLI errors: \(failures.joined(separator: "; "))")
        }
    }

    private static func performStashURLs(urls: [String], tags: [String]) async {
        var successes = 0
        var failures: [String] = []
        for url in urls {
            do {
                _ = try await StashCLI.shared.addURL(url: url, tags: tags)
                successes += 1
            } catch {
                failures.append("\(url): \(error.localizedDescription)")
            }
        }
        if successes > 0 {
            let body = successes == 1
                ? "URL added to your stash."
                : "\(successes) URLs added to your stash."
            notify(title: "Stashed", body: body)
            appendLog("Stashed \(successes) URL(s)")
            await postIngestNotification()
        }
        if !failures.isEmpty {
            notify(
                title: "Stash failed",
                body: failures.joined(separator: "; ")
            )
            appendLog("CLI errors: \(failures.joined(separator: "; "))")
        }
    }

    @MainActor
    private static func postIngestNotification() {
        NotificationCenter.default.post(name: .stashDidIngest, object: nil)
    }

    private func notify(title: String, body: String) {
        Self.notify(title: title, body: body)
    }

    private static func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    private func log(_ msg: String) {
        Self.appendLog(msg)
    }

    private static func appendLog(_ msg: String) {
        let path = "/tmp/stash-services.log"
        let line = "\(Date()): \(msg)\n"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: path) {
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }
}
