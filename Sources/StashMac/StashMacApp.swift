import AppKit
import Quartz
import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let servicesProvider = ServicesProvider()
    private var fieldEditorObservers: [NSObjectProtocol] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Earliest reliable hook — install the field-editor interceptor on
        // every NSWindow before the user can focus a text field. Layer 5
        // of the autofill suppression stack; without this, the empty
        // rounded ghost popup appears once per session the first time any
        // AppKit menu/text-input infrastructure activates (including the
        // first focus on any FilterField).
        fieldEditorObservers = installFieldEditorInterceptorsForAllWindows()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Re-sweep in case any windows came up between
        // applicationWillFinishLaunching and now.
        for window in NSApp.windows {
            installFieldEditorInterceptor(on: window)
        }
        // Touch the QLPreviewPanel singleton early so its one-time
        // creation happens during launch — when our interceptors
        // are fully wired — rather than the first time the user
        // hits spacebar. Newer panels created by AppKit sometimes
        // leak the autofill popup once on first instantiation if
        // the interceptor isn't ready.
        if let panel = QLPreviewPanel.shared() {
            installFieldEditorInterceptor(on: panel)
        }
        NSApp.servicesProvider = servicesProvider
        NSUpdateDynamicServices()
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        ) { _, _ in }
    }

    deinit {
        for token in fieldEditorObservers {
            NotificationCenter.default.removeObserver(token)
        }
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
                // No default shortcut — ⌘? is reserved for homebar in this
                // user's setup. Rebind via System Settings → Keyboard →
                // App Shortcuts if you want a hotkey for this menu item.
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
