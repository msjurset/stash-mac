import AppKit
import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let servicesProvider = ServicesProvider()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = servicesProvider
        NSUpdateDynamicServices()
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        ) { _, _ in }
    }
}

@main
struct StashMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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

        MenuBarExtra("Stash", image: clipboardMonitor.isWatching ? "MenuBarIcon" : "MenuBarIconIdle") {
            ClipboardMenuView()
                .environment(clipboardMonitor)
                .environment(selectionGrabber)
        }
        .menuBarExtraStyle(.menu)
    }
}
