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
/// editor. All eight flags must be disabled, and they have to be
/// re-disabled in three lifecycle points — the field editor is
/// re-initialized across responder transitions and restores defaults
/// each time.
final class NoAutoFillTextField: NSTextField {
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { Self.disableAutoFeatures(on: currentEditor() as? NSTextView) }
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
    }
}
