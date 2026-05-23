import SwiftUI
import AppKit
import VimEngine

/// SwiftUI wrapper around VimHostTextView. The one canonical
/// multi-line text editor for stash-mac — every place that needs
/// multi-line editing with optional vim mode goes through this.
///
/// Visual customization (background, font, container inset, scroll
/// chrome) is exposed as init parameters so the same component can
/// host the Notes detail editor, the popover Extracted-Text edit,
/// the Edit / Add sheets, and the rule template editor without
/// per-call subclassing.
///
/// **Slash command UX**: typing `/<word>` opens the
/// SlashSuggestionView dropdown. Arrow / Tab / Enter / Esc / Space
/// keys route through the suggestion's binding. Committing `/vim`
/// activates the engine via the parent's VimModeController.
///
/// **Vim lifecycle**: the parent provides a `vimEngine: VimEngine?`
/// binding. Non-nil → engine is active and owns the keyboard. The
/// editor watches `currentMode` so it can clear slash autocomplete
/// state while vim is on (vim's `/` is search, not slash command).
struct VimHostEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var slashPrefix: String
    @Binding var pendingCursor: Int?

    var currentMode: EditorMode?
    var vimEngine: VimEngine?

    // Visual config — fed straight into the NSTextView. Defaults
    // are the body-font / opaque-background shape used by the
    // sheet editors; popover / notes call sites override.
    var font: NSFont = .systemFont(ofSize: 13)
    var textContainerInset: NSSize = NSSize(width: 8, height: 8)
    var drawsBackground: Bool = true
    var backgroundColor: NSColor = .textBackgroundColor
    var monospaced: Bool = false

    /// Cmd+Enter / `:w` callback. nil = no submit semantics; submit
    /// keystrokes fall through to default behavior.
    var onSubmit: (() -> Void)?
    /// Caller-supplied handler for slash-suggestion navigation
    /// keys. Returns true to consume the event. Wired by the parent
    /// that owns the @Binding slashSelectedIndex state.
    var onSlashKeyEvent: ((VimHostTextView.SlashKeyEvent) -> Bool)?
    /// Fired on textDidBeginEditing / textDidEndEditing so SwiftUI
    /// callers can mirror focus into their own @State (e.g.
    /// StashTextEditor's idle/focused height expansion). Distinct
    /// from SwiftUI's @FocusState which doesn't see AppKit text
    /// views.
    var onFocusChanged: ((Bool) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = drawsBackground
        if drawsBackground { scrollView.backgroundColor = backgroundColor }

        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)

        let containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        let textContainer = NSTextContainer(containerSize: containerSize)
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)

        let tv = VimHostTextView(frame: .zero, textContainer: textContainer)
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]

        let resolvedFont: NSFont = monospaced
            ? NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular)
            : font
        tv.font = resolvedFont
        tv.textColor = .textColor
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.textContainerInset = textContainerInset
        tv.drawsBackground = drawsBackground
        if drawsBackground { tv.backgroundColor = backgroundColor }

        tv.delegate = context.coordinator
        let coordinator = context.coordinator
        tv.vimEngineProvider = { coordinator.parent.vimEngine }
        tv.currentModeProvider = { coordinator.parent.currentMode }
        tv.isShowingSlash = { !coordinator.parent.slashPrefix.isEmpty }
        tv.slashKeyHandler = { event in
            coordinator.parent.onSlashKeyEvent?(event) ?? false
        }
        tv.submitHandler = { coordinator.parent.onSubmit?() }
        context.coordinator.textView = tv

        tv.string = text

        scrollView.documentView = tv
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        // Refresh the coordinator's parent so non-@Binding values
        // (e.g. vimEngine) read live without rebinding closures.
        context.coordinator.parent = self

        guard let tv = scrollView.documentView as? VimHostTextView else { return }

        if tv.string != text {
            context.coordinator.updatingFromBinding = true
            tv.string = text
            tv.textStorage?.edited(.editedCharacters, range: NSRange(location: 0, length: 0), changeInLength: 0)
            context.coordinator.updatingFromBinding = false
        }

        // One-shot caret request — apply and clear so SwiftUI
        // doesn't re-apply it on every render. Async-clear so the
        // SetState fires outside this update cycle.
        if let cursor = pendingCursor {
            let length = (tv.string as NSString).length
            let clamped = max(0, min(cursor, length))
            tv.setSelectedRange(NSRange(location: clamped, length: 0))
            DispatchQueue.main.async {
                self.pendingCursor = nil
            }
        }

        // On vim→off transition, restore first responder to the
        // text view (the mode-badge button often steals it when
        // clicked to exit) and clear the lingering block cursor.
        let vimActiveNow = (currentMode == .vim)
        if context.coordinator.lastVimActive && !vimActiveNow {
            DispatchQueue.main.async {
                if let window = tv.window {
                    if !window.isKeyWindow {
                        window.makeKeyAndOrderFront(nil)
                    }
                    window.makeFirstResponder(tv)
                }
                tv.invalidateBlockCursorArea()
            }
        }
        context.coordinator.lastVimActive = vimActiveNow
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: VimHostEditor
        weak var textView: VimHostTextView?
        var updatingFromBinding = false
        var lastVimActive: Bool = false

        init(_ parent: VimHostEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !updatingFromBinding else { return }
            guard let tv = notification.object as? VimHostTextView else { return }

            // Check for // escape. Replace with / and suppress autocomplete.
            let ns = tv.string as NSString
            let cursor = tv.selectedRange().location
            if cursor >= 2 && ns.character(at: cursor - 1) == 0x2F && ns.character(at: cursor - 2) == 0x2F {
                let range = NSRange(location: cursor - 2, length: 2)
                if tv.shouldChangeText(in: range, replacementString: "/") {
                    tv.replaceCharacters(in: range, with: "/")
                    tv.didChangeText()
                    tv.setSelectedRange(NSRange(location: cursor - 1, length: 0))
                }
            }

            parent.text = tv.string

            // Vim owns `/` (search). Suppress slash autocomplete
            // while the editor is in vim mode regardless of submode.
            if parent.currentMode == .vim {
                parent.slashPrefix = ""
                return
            }
            parent.slashPrefix = Self.findSlashPrefix(in: tv)
        }

        func textDidBeginEditing(_ notification: Notification) {
            parent.onFocusChanged?(true)
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.onFocusChanged?(false)
        }

        /// Walk back from the caret looking for the start of a
        /// slash-command token (`/<alphanum/-/_>*`). Returns the
        /// full `/word` substring, or "" when there's no live
        /// slash context at the cursor.
        @MainActor
        static func findSlashPrefix(in tv: NSTextView) -> String {
            let cursorLocation = tv.selectedRange().location
            let string = tv.string
            guard cursorLocation > 0, cursorLocation <= string.count else { return "" }

            let nsString = string as NSString
            var i = cursorLocation - 1
            while i >= 0 {
                let ch = nsString.character(at: i)
                guard let scalar = Unicode.Scalar(ch) else { return "" }
                if scalar == "/" {
                    // Only trigger slash commands if preceded by space or
                    // start of line. This ensures things like `//` or
                    // `pollinators./` don't trigger accidentally.
                    if i > 0 {
                        let prev = nsString.character(at: i - 1)
                        if let prevScalar = Unicode.Scalar(prev),
                           !CharacterSet.whitespacesAndNewlines.contains(prevScalar) {
                            return ""
                        }
                    }
                    return nsString.substring(with: NSRange(location: i, length: cursorLocation - i))
                } else if CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-" {
                    i -= 1
                } else {
                    return ""
                }
            }
            return ""
        }
    }
}
