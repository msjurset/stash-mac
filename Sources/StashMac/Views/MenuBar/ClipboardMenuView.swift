import SwiftUI

struct ClipboardMenuView: View {
    @Environment(ClipboardMonitor.self) private var monitor
    @Environment(SelectionGrabber.self) private var grabber
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Stash Selection") {
            grabber.stashSelection()
        }
        .keyboardShortcut("s", modifiers: [.command, .shift])

        Button("Stash Clipboard") {
            grabber.stashClipboard()
        }

        Button {
            monitor.isWatching.toggle()
        } label: {
            Label("Watch Clipboard", systemImage: monitor.isWatching ? "checkmark.circle.fill" : "circle")
        }

        Divider()

        if !monitor.pendingURLs.isEmpty {
            Section("Captured (\(monitor.pendingURLs.count))") {
                ForEach(monitor.pendingURLs) { pending in
                    Menu(truncateURL(pending.url)) {
                        Button("Stash") { monitor.stashURL(pending) }
                        Button("Dismiss") { monitor.dismissURL(pending) }
                    }
                }

                Divider()

                if monitor.pendingURLs.count > 1 {
                    Button("Stash All") { monitor.stashAll() }
                }
                Button("Clear All") { monitor.clearPending() }
            }

            Divider()
        }

        if !monitor.recentStashes.isEmpty {
            Section("Stashed") {
                ForEach(monitor.recentStashes.prefix(5)) { stash in
                    Text(truncateURL(stash.url))
                        .font(.caption)
                }
            }

            Divider()
        }

        Button("Open Stash") {
            if let window = NSApp.windows.first(where: { $0.title == "Stash" || $0.identifier?.rawValue.contains("main") == true }) {
                window.makeKeyAndOrderFront(nil)
            } else {
                openWindow(id: "main")
            }
            NSApp.activate(ignoringOtherApps: true)
        }

        Divider()

        Button("Quit") {
            NSApp.terminate(nil)
        }
    }

    private func truncateURL(_ url: String) -> String {
        if url.count > 60 {
            return String(url.prefix(57)) + "..."
        }
        return url
    }
}
