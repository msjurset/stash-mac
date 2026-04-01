import SwiftUI

@main
struct StashMacApp: App {
    @State private var store = StashStore()
    @State private var clipboardMonitor = ClipboardMonitor()
    @State private var selectionGrabber = SelectionGrabber()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environment(store)
        }
        .defaultSize(width: 1100, height: 700)
        .commands {
            CommandGroup(replacing: .help) {
                Button("Stash Help") {
                    openWindow(id: "help")
                }
                .keyboardShortcut("?", modifiers: .command)
            }
        }

        WindowGroup("Stash Help", id: "help") {
            HelpView()
        }
        .defaultSize(width: 800, height: 550)

        MenuBarExtra("Stash", systemImage: clipboardMonitor.isWatching ? "tray.full.fill" : "tray") {
            ClipboardMenuView()
                .environment(clipboardMonitor)
                .environment(selectionGrabber)
        }
        .menuBarExtraStyle(.menu)
    }
}
