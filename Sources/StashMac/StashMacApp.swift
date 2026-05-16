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
    @State private var aiPrefs = AIPrefsStore()
    @Environment(\.openWindow) private var openWindow

    /// Read from the same `@AppStorage` key the Appearance settings
    /// pane writes to. Re-renders the WindowGroup body when the user
    /// flips the picker, so theme changes take effect live with no
    /// relaunch.
    @AppStorage("appTheme") private var appTheme: AppTheme = .system

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environment(store)
                .environment(aiPrefs)
                .preferredColorScheme(appTheme.colorScheme)
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
            // File ▸ Import Archive… — pairs with the right-click
            // export surfaces on selections / tags / collections.
            // File ▸ Import Bookmarks… — auto-discovers the active
            // Chrome / Firefox profile but lets the user override.
            CommandGroup(after: .importExport) {
                Button("Import Archive…") {
                    if let path = ExportPanels.chooseImportSource() {
                        store.importArchive(path: path)
                    }
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                Button("Import Bookmarks…") {
                    NotificationCenter.default.post(
                        name: .stashOpenImportBookmarks,
                        object: nil
                    )
                }
                Button("Import Browser History…") {
                    NotificationCenter.default.post(
                        name: .stashOpenImportHistory,
                        object: nil
                    )
                }
                Button("Fetch Files via URL…") {
                    NotificationCenter.default.post(
                        name: .stashOpenFetchURL,
                        object: nil
                    )
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])
            }
        }

        // Parameterized so the contextual ? shortcut can land on the
        // topic that matches the user's current sidebar nav. The
        // menu-item path passes nil and lands on Getting Started.
        WindowGroup("Stash Help", id: "help", for: HelpTopic.self) { $topic in
            HelpView(initialTopic: topic ?? .gettingStarted)
                .preferredColorScheme(appTheme.colorScheme)
        }
        .defaultSize(width: 800, height: 550)

        // Settings scene. The Settings menu item under "Stash" (⌘,)
        // opens this automatically — SwiftUI handles the routing.
        Settings {
            SettingsView()
                .environment(store)
                .environment(aiPrefs)
                .preferredColorScheme(appTheme.colorScheme)
        }

        MenuBarExtra("Stash", image: clipboardMonitor.isWatching ? "MenuBarIcon" : "MenuBarIconIdle") {
            ClipboardMenuView()
                .environment(clipboardMonitor)
                .environment(selectionGrabber)
        }
        .menuBarExtraStyle(.menu)
    }
}

extension Notification.Name {
    /// Posted by the File ▸ Import Bookmarks… menu item; ContentView
    /// listens and flips its local sheet state. Notification routing
    /// avoids putting a `.sheet` on the WindowGroup body, which on
    /// macOS 15 silently breaks `.popover` presentations elsewhere
    /// (most visibly: the per-row icon thumbnail popover in the
    /// items list).
    static let stashOpenImportBookmarks = Notification.Name("stash.openImportBookmarks")
    /// Posted by the File ▸ Import Browser History… menu item;
    /// ContentView listens and presents the history-import sheet.
    static let stashOpenImportHistory = Notification.Name("stash.openImportHistory")
    /// Posted by the File ▸ Fetch from URL… menu item; ContentView
    /// listens and presents the fetch-URL picker sheet.
    static let stashOpenFetchURL = Notification.Name("stash.openFetchURL")
}
