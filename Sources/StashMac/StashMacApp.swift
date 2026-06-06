import AppKit
import Quartz
import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let servicesProvider = ServicesProvider()
    private var fieldEditorObservers: [NSObjectProtocol] = []
    private var eventMonitor: Any?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Layer 0: Force-set the prediction-subsystem defaults in our app's
        // persistent domain. Earlier attempts at register() (only
        // fills gaps) and setVolatileDomain on NSArgumentDomain
        // (didn't actually take — AppKit ignored those values when
        // reading the predictive panel config) both let the empty
        // ghost popup back through on launches when the user has
        // system-wide predictive text enabled. set() writes to our
        // app's persistent domain which AppKit reads with higher
        // priority than NSGlobalDomain, so our values win. Trade-
        // off: persists to ~/Library/Preferences/<bundle>.plist,
        // but they're all "false" booleans for features we never
        // want — harmless on disk.
        let prefs = UserDefaults.standard
        for key in [
            "NSAutomaticTextCompletionEnabled",
            "NSAutomaticInlinePredictionEnabled",
            "WebAutomaticTextReplacementEnabled",
            "NSAllowsCharacterPickerTouchBarItem",
            "NSAutomaticSpellingCorrectionEnabled",
            "NSAutomaticTextReplacementEnabled",
            "NSAutomaticQuoteSubstitutionEnabled",
            "NSAutomaticDashSubstitutionEnabled",
            "NSAutomaticDataDetectionEnabled",
            "NSAutomaticLinkDetectionEnabled",
        ] {
            prefs.set(false, forKey: key)
        }

        // Earliest reliable hook — install the field-editor interceptor on
        // every NSWindow before the user can focus a text field. Layer 5
        // of the autofill suppression stack.
        for window in NSApp.windows {
            installFieldEditorInterceptor(on: window)
        }

        // didBecomeKey covers any future window that comes up.
        let didKey = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let window = notification.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                installFieldEditorInterceptor(on: window)
                reapPredictivePanels()
            }
        }
        fieldEditorObservers.append(didKey)

        // Any window that's added later (sheets, popovers that get
        // promoted) gets wrapped at order-in time.
        let didUpdate = NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let window = notification.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                installFieldEditorInterceptor(on: window)
            }
        }
        fieldEditorObservers.append(didUpdate)

        // Belt-and-suspenders: before any user interaction reaches a
        // text field, re-sweep every window.
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown]
        ) { event in
            MainActor.assumeIsolated {
                for window in NSApp.windows {
                    installFieldEditorInterceptor(on: window)
                }
                reapPredictivePanels()
                for delay in [0.05, 0.15, 0.35, 0.7] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        reapPredictivePanels()
                    }
                }
            }
            return event
        }
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

        // Always-on watcher: scans the window tree every 0.5s and
        // logs the first sighting of any predictive-text / Writing
        // Tools / autofill-style subview. Runs in production so the
        // unified log captures regressions during normal use.
        PhantomPopupDetector.startWatching()

        // Cold-launch flash fix. Fan a series of timer-based sweeps across
        // the first few seconds of life so any predictive panel gets ordered-out
        // within one runloop turn of instantiation.
        reapPredictivePanels()
        for delay in [0.05, 0.15, 0.3, 0.6, 1.2, 2.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                reapPredictivePanels()
            }
        }

        // didChangeOcclusionStateNotification -> reap immediately when occlusion state changes
        let didOcclusion = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                reapPredictivePanels()
            }
        }
        fieldEditorObservers.append(didOcclusion)

        // didBecomeKeyNotification -> reap on focus shift
        let keyToken = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                reapPredictivePanels()
            }
        }
        fieldEditorObservers.append(keyToken)

        // Check mode for `make phantom-check`: launch with
        // STASH_PHANTOM_CHECK=1 → app exits after a fixed window with
        // status 0 (no hits) or 1 (any hit). Driver is the Makefile
        // target; output goes to stderr.
        let env = ProcessInfo.processInfo.environment
        if env["STASH_PHANTOM_CHECK"] == "1" {
            let seconds: TimeInterval =
                Double(env["STASH_PHANTOM_CHECK_SECONDS"] ?? "") ?? 30
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                let hits = PhantomPopupDetector.observedHits
                let prefix = "STASH_PHANTOM_CHECK"
                if hits.isEmpty {
                    let msg = "\(prefix) ok (no hits in \(Int(seconds))s)\n"
                    FileHandle.standardError.write(Data(msg.utf8))
                    exit(0)
                } else {
                    var summary = "\(prefix) FAIL: \(hits.count) hit(s)\n"
                    for h in hits {
                        summary += """
                              - \(h.className) in "\(h.windowTitle)" \
                            frame=\(Int(h.frame.width))x\(Int(h.frame.height)) \
                            hasText=\(h.hasTextDescendants)

                            """
                    }
                    FileHandle.standardError.write(Data(summary.utf8))
                    exit(1)
                }
            }
        }
    }

    deinit {
        for token in fieldEditorObservers {
            NotificationCenter.default.removeObserver(token)
        }
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
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
    @State private var helpModel = HelpOverlayModel()
    @Environment(\.openWindow) private var openWindow

    /// Read from the same `@AppStorage` key the Appearance settings
    /// pane writes to. Re-renders the WindowGroup body when the user
    /// flips the picker, so theme changes take effect live with no
    /// relaunch.
    @AppStorage("appTheme") private var appTheme: AppTheme = .system

    var body: some Scene {
        WindowGroup(id: "main") {
            ZStack {
                // 1. Root host for the coordinate space - must fill the whole window
                Color.clear
                    .ignoresSafeArea()
                    .coordinateSpace(name: "window")
                
                // 2. The main app content - respects safe areas (toolbar, etc.)
                ContentView()
                    .environment(store)
                    .environment(aiPrefs)
                    .environment(helpModel)
                    .preferredColorScheme(appTheme.colorScheme)
                    .disabled(helpModel.isActive)
                
                // 3. The Help Overlay - covers everything including the toolbar
                if helpModel.isActive {
                    HelpOverlayView()
                        .environment(helpModel)
                        .ignoresSafeArea()
                        .zIndex(100)
                }
            }
            .overlay(alignment: .top) { ToastOverlay() }
        }
        .defaultSize(width: 1100, height: 700)
        .commands {
            CommandGroup(replacing: .help) {
                Button("Interactive Help") {
                    helpModel.isActive.toggle()
                }
                .keyboardShortcut("/", modifiers: [.command, .shift])

                Button("Stash Help") {
                    openWindow(id: "help")
                }
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
                .environment(helpModel)
                .preferredColorScheme(appTheme.colorScheme)
        }
        .defaultSize(width: 800, height: 550)

        // Settings scene. The Settings menu item under "Stash" (⌘,)
        // opens this automatically — SwiftUI handles the routing.
        Settings {
            SettingsView()
                .environment(store)
                .environment(aiPrefs)
                .environment(helpModel)
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
