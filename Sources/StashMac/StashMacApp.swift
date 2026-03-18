import SwiftUI

@main
struct StashMacApp: App {
    @State private var store = StashStore()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup {
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
    }
}
