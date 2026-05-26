import SwiftUI
import AppKit

/// Keys the suggestion / auto-complete infrastructure cares about.
/// Shared across `FilterField`, `SearchFieldKeyMonitor`, and
/// `TagAwareSearchField` so every input type maps the same way.
enum SuggestKey {
    case tab, shiftTab, arrowDown, arrowUp, ctrlJ, ctrlK, enter, escape
}

/// Drop-in replacement for SwiftUI's `TextField` on macOS that suppresses
/// AppKit's autofill / autocomplete "phantom box" — the empty rounded
/// rectangle that appears under a focused SwiftUI TextField and can't be
/// hidden by any SwiftUI modifier.
///
/// Use `FilterField` for **every** editable text input in this project.
/// Any plain `TextField` will bring the phantom box back.
struct FilterField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    var font: NSFont = .preferredFont(forTextStyle: .body)
    var isBordered: Bool = false
    var backgroundColor: NSColor = .clear
    /// Makes the field the window's first responder after it appears.
    var autoFocus: Bool = false
    var onSubmit: (() -> Void)?
    /// Return `true` to consume the key event; `false` to let AppKit
    /// handle it (e.g. default Tab focus navigation).
    var onKey: ((SuggestKey) -> Bool)?
    var onBeginEditing: (() -> Void)?
    var onEndEditing: (() -> Void)?

    func makeNSView(context: Context) -> NoAutoFillTextField {
        let field = NoAutoFillTextField()
        field.placeholderString = placeholder
        field.font = font
        field.isBordered = isBordered
        field.backgroundColor = backgroundColor
        field.drawsBackground = backgroundColor != .clear
        field.focusRingType = .none
        field.delegate = context.coordinator
        field.stringValue = text
        // Route the field's "I just became first responder" event through
        // the coordinator so callers' `onBeginEditing` fires on click-in
        // (focus arrival) — not just on the first text edit, which is
        // when NSText's `controlTextDidBeginEditing` would fire.
        field.onFocusReceived = { [weak coord = context.coordinator] in
            coord?.handleFocusReceived()
        }
        if autoFocus {
            DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        }
        return field
    }

    func updateNSView(_ nsView: NoAutoFillTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        if nsView.placeholderString != placeholder {
            nsView.placeholderString = placeholder
        }
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: FilterField

        init(_ parent: FilterField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            // Fires on the first edit (typing), not on click-in. The
            // focus-on-arrival path (`handleFocusReceived`) is what most
            // callers want. Keep this notification too for compatibility
            // with any caller that genuinely wants "started editing".
            parent.onBeginEditing?()
        }

        /// Called by `NoAutoFillTextField.becomeFirstResponder` so that
        /// `onBeginEditing` fires on focus arrival (click-in / programmatic
        /// focus), not just on the first edit. SwiftUI popover-on-focus
        /// patterns depend on this — `controlTextDidBeginEditing` is too
        /// late.
        func handleFocusReceived() {
            parent.onBeginEditing?()
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            parent.onEndEditing?()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            let key: SuggestKey?
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):     key = .enter
            case #selector(NSResponder.insertTab(_:)):         key = .tab
            case #selector(NSResponder.insertBacktab(_:)):     key = .shiftTab
            case #selector(NSResponder.moveDown(_:)):          key = .arrowDown
            case #selector(NSResponder.moveUp(_:)):            key = .arrowUp
            case #selector(NSResponder.cancelOperation(_:)):   key = .escape
            default: key = nil
            }
            // onKey gets first shot on every mapped key, including Enter.
            if let key, let onKey = parent.onKey, onKey(key) { return true }
            // Fall through: Enter fires onSubmit (if set) after onKey declines it.
            if key == .enter, let onSubmit = parent.onSubmit {
                onSubmit()
                return true
            }
            return false
        }
    }
}

/// `NSTextField` subclass that suppresses AppKit's autofill/autocomplete
/// popup and every other "helpful" automatic text feature on its field
/// editor. All eight legacy auto-* flags must be disabled, plus the macOS
/// 14 inline-prediction trait and the macOS 15 Writing Tools traits, and
/// they have to be re-disabled in *four* lifecycle points — the field
/// editor is re-initialized across responder transitions and restores
/// defaults each time. The cell-level hook (layer 4) is the only place
/// early enough to suppress the popup on first focus per session.
final class NoAutoFillTextField: NSTextField {
    /// Fires when the field actually becomes first responder (i.e. on
    /// click into / programmatic focus), as opposed to NSText's
    /// `controlTextDidBeginEditing` which only fires on the first edit
    /// operation. Used by the popover-on-focus pattern in InlineEditField
    /// and the regex-guide trigger.
    var onFocusReceived: (() -> Void)?

    /// Force the cell to be our subclass so the cell-level
    /// `setUpFieldEditorAttributes` override gets installed. Without this
    /// override AppKit hands the field its default `NSTextFieldCell` and
    /// the popup appears on the first focus per session before any of the
    /// instance-level lifecycle hooks fire.
    override class var cellClass: AnyClass? {
        get { NoAutoFillTextFieldCell.self }
        set {}
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Layer-5 install at the earliest moment a field's window
        // is known. AppKit calls this synchronously the instant the
        // view is added to a window — before any focus event is
        // possible — so our shared field-editor singleton is in
        // place by the time becomeFirstResponder fires. This makes
        // the per-call-site `DispatchQueue.main.async {
        // installFieldEditorInterceptor(...) }` race patches
        // unnecessary. Sheets / popovers / new windows are all
        // covered automatically.
        if let window {
            installFieldEditorInterceptor(on: window)
        }
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            Self.disableAutoFeatures(on: currentEditor() as? NSTextView)
            onFocusReceived?()
        }
        return ok
    }

    override func textDidBeginEditing(_ notification: Notification) {
        super.textDidBeginEditing(notification)
        Self.disableAutoFeatures(on: notification.object as? NSTextView)
    }

    override func textShouldBeginEditing(_ textObject: NSText) -> Bool {
        let ok = super.textShouldBeginEditing(textObject)
        Self.disableAutoFeatures(on: textObject as? NSTextView)
        return ok
    }

    static func disableAutoFeatures(on textView: NSTextView?) {
        guard let tv = textView else { return }
        tv.isAutomaticTextCompletionEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticDataDetectionEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        // macOS 14 added an inline-prediction surface that renders as the
        // empty rounded ghost popup beneath the field on focus. None of
        // the legacy auto-* flags affect it.
        if #available(macOS 14.0, *) {
            tv.inlinePredictionType = .no
        }
        // macOS 15 routes predictive text through Apple Intelligence
        // Writing Tools — the popup reappears here unless we explicitly
        // opt out at the per-editor level.
        if #available(macOS 15.0, *) {
            tv.writingToolsBehavior = .none
            tv.allowedWritingToolsResultOptions = []
        }
    }
}

/// Cell that disables predictions on the field editor *before* it begins
/// taking input. The instance-level lifecycle hooks (`becomeFirstResponder`,
/// `textDidBeginEditing`, etc.) fire AFTER `super.becomeFirstResponder()`,
/// but on Sequoia the inline-prediction popup is scheduled inside that
/// super call — by the time the hooks run, the popup has already been laid
/// out once. `setUpFieldEditorAttributes` runs earlier, before AppKit
/// attaches the editor for input, which is the only point that suppresses
/// the popup on first focus per session.
final class NoAutoFillTextFieldCell: NSTextFieldCell {
    override func setUpFieldEditorAttributes(_ textObj: NSText) -> NSText {
        if let window = textObj.window {
            print("[PHANTOM] NoAutoFillTextFieldCell.setUpFieldEditorAttributes window: \"\(window.title)\" frame: \(window.frame)")
        } else {
            print("[PHANTOM] NoAutoFillTextFieldCell.setUpFieldEditorAttributes window: nil")
        }
        let configured = super.setUpFieldEditorAttributes(textObj)
        if let editor = configured as? NSTextView {
            NoAutoFillTextField.disableAutoFeatures(on: editor)
        }
        return configured
    }
}
