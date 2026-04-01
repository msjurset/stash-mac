import AppKit
import Combine

@Observable
@MainActor
final class ClipboardMonitor {
    var isWatching = true {
        didSet {
            if isWatching {
                lastChangeCount = NSPasteboard.general.changeCount
                startPolling()
            } else {
                stopPolling()
            }
        }
    }
    var pendingURLs: [PendingURL] = []
    var recentStashes: [QuickStash] = []

    struct PendingURL: Identifiable {
        let id = UUID()
        let url: String
        let detectedAt: Date
    }

    struct QuickStash: Identifiable {
        let id = UUID()
        let url: String
        let title: String
        let date: Date
    }

    private let cli = StashCLI.shared
    private var lastChangeCount: Int = 0
    private var timer: AnyCancellable?
    private var seenURLs: Set<String> = []

    init() {
        lastChangeCount = NSPasteboard.general.changeCount
        startPolling()
    }

    func stashURL(_ pending: PendingURL) {
        pendingURLs.removeAll { $0.id == pending.id }
        Task {
            do {
                let item = try await cli.addURL(url: pending.url)
                let stash = QuickStash(url: pending.url, title: item.title, date: Date())
                recentStashes.insert(stash, at: 0)
                if recentStashes.count > 10 {
                    recentStashes = Array(recentStashes.prefix(10))
                }
            } catch {
                // Put it back on failure
                pendingURLs.insert(pending, at: 0)
            }
        }
    }

    func stashAll() {
        let all = pendingURLs
        pendingURLs.removeAll()
        for pending in all {
            Task {
                do {
                    let item = try await cli.addURL(url: pending.url)
                    let stash = QuickStash(url: pending.url, title: item.title, date: Date())
                    recentStashes.insert(stash, at: 0)
                } catch {}
            }
        }
    }

    func dismissURL(_ pending: PendingURL) {
        pendingURLs.removeAll { $0.id == pending.id }
    }

    func clearPending() {
        pendingURLs.removeAll()
    }

    private func startPolling() {
        timer = Timer.publish(every: 2, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.checkClipboard()
                }
            }
    }

    private func stopPolling() {
        timer?.cancel()
        timer = nil
    }

    private func checkClipboard() {
        let pasteboard = NSPasteboard.general
        let currentCount = pasteboard.changeCount
        guard currentCount != lastChangeCount else { return }
        lastChangeCount = currentCount

        guard let content = pasteboard.string(forType: .string) else { return }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              url.host != nil else {
            return
        }

        // Skip if already pending or already stashed
        if seenURLs.contains(trimmed) { return }
        if pendingURLs.contains(where: { $0.url == trimmed }) { return }
        if recentStashes.contains(where: { $0.url == trimmed }) { return }

        seenURLs.insert(trimmed)
        pendingURLs.append(PendingURL(url: trimmed, detectedAt: Date()))
    }
}
