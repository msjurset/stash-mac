import AppKit
import SwiftUI

/// A floating, HUD-like panel for global search, similar to Spotlight or Raycast.
final class GlobalSearchPanel: NSPanel {
    /// Guards against premature `orderOut` in `resignKey()` while the panel is mid-presentation.
    var isPresenting: Bool = false

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.titled, .fullSizeContentView, .closable, .resizable],
            backing: .buffered,
            defer: false
        )

        self.isFloatingPanel = true
        self.hidesOnDeactivate = false
        self.level = .modalPanel
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true
        self.isMovableByWindowBackground = true
        self.isOpaque = false
        self.backgroundColor = .clear

        // Hide standard window buttons
        self.standardWindowButton(.closeButton)?.isHidden = true
        self.standardWindowButton(.miniaturizeButton)?.isHidden = true
        self.standardWindowButton(.zoomButton)?.isHidden = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func fieldEditor(_ createFlag: Bool, for object: Any?) -> NSText? {
        if let custom = sharedFieldEditor(for: object) {
            return custom
        }
        return super.fieldEditor(createFlag, for: object)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags == .command, let chars = event.charactersIgnoringModifiers?.lowercased() {
                if chars == "k" || chars == "f" || chars == "/" {
                    self.orderOut(nil)
                    return true
                }
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func resignKey() {
        super.resignKey()
        if isPresenting {
            return
        }
        // Keep panel visible if a child popover window (such as the regex guide) is attached
        if let children = self.childWindows, !children.isEmpty {
            return
        }
        self.orderOut(nil)
    }

    override func cancelOperation(_ sender: Any?) {
        self.orderOut(nil)
    }
}

/// Manages the singleton floating Global Search panel (`⌘K`, `⌘F`, `⌘/`).
@MainActor
final class GlobalSearchController {
    static let shared = GlobalSearchController()

    private var panel: GlobalSearchPanel?

    var store: StashStore?
    var aiPrefs: AIPrefsStore?
    var helpModel: HelpOverlayModel?

    func configure(store: StashStore, aiPrefs: AIPrefsStore, helpModel: HelpOverlayModel) {
        self.store = store
        self.aiPrefs = aiPrefs
        self.helpModel = helpModel
    }

    func toggle() {
        if panel?.isVisible == true {
            hide()
        } else {
            show()
        }
    }

    func show() {
        guard let store else { return }
        let aiPrefs = self.aiPrefs ?? AIPrefsStore()
        let helpModel = self.helpModel ?? HelpOverlayModel()

        store.globalSearchTick &+= 1

        if panel == nil {
            let rect = NSRect(x: 0, y: 0, width: 820, height: 520)
            let newPanel = GlobalSearchPanel(contentRect: rect)
            newPanel.minSize = NSSize(width: 720, height: 420)

            // Layer-5 autofill suppression for the panel
            installFieldEditorInterceptor(on: newPanel)

            let searchView = QuickSearchView(onDismiss: { [weak self] in
                self?.hide()
            })
            .environment(store)
            .environment(aiPrefs)
            .environment(helpModel)
            .ignoresSafeArea()

            let hostingView = NSHostingView(rootView: searchView)
            hostingView.sizingOptions = []

            let visualEffect = NSVisualEffectView(frame: NSRect(origin: .zero, size: rect.size))
            visualEffect.autoresizingMask = [.width, .height]
            visualEffect.material = .hudWindow
            visualEffect.state = .active
            visualEffect.blendingMode = .behindWindow
            visualEffect.wantsLayer = true
            visualEffect.layer?.cornerRadius = 12
            visualEffect.layer?.masksToBounds = true
            visualEffect.layer?.borderWidth = 1
            visualEffect.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

            hostingView.frame = visualEffect.bounds
            hostingView.autoresizingMask = [.width, .height]
            visualEffect.addSubview(hostingView)

            newPanel.contentView = visualEffect
            newPanel.center()
            self.panel = newPanel
        }

        guard let panel else { return }

        // Detach the shared custom field editor from any active text field in the main window
        // before moving focus to the global search panel.
        if let keyWin = NSApp.keyWindow, keyWin !== panel {
            keyWin.makeFirstResponder(nil)
        }

        panel.isPresenting = true
        NSApp.activate(ignoringOtherApps: true)
        panel.level = .modalPanel
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)

        DispatchQueue.main.async { [weak panel] in
            guard let panel else { return }
            panel.level = .modalPanel
            panel.orderFrontRegardless()
            panel.makeKeyAndOrderFront(nil)
            panel.isPresenting = false
        }
    }

    func hide() {
        panel?.isPresenting = false
        panel?.orderOut(nil)
    }
}
