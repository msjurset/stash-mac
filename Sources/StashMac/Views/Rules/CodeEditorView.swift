import AppKit
import SwiftUI
import VimEngine

/// A syntax-highlighted YAML/script editor with auto-completion.
struct CodeEditorView: NSViewRepresentable {
    @Binding var text: String
    /// Non-nil = vim mode is active. The engine owns key routing while set.
    var vimEngine: VimEngine? = nil
    /// Current `/partial` slash-command run at the caret. Empty when the
    /// caret isn't inside a slash context. The host renders the
    /// suggestion pill from this; the editor writes to it.
    var slashPrefix: Binding<String>? = nil
    /// Host-side handler for arrow/Enter/Tab/Esc/Space while the slash
    /// pill is visible. Returning true marks the event as consumed.
    var onSlashKeyEvent: ((VimHostTextView.SlashKeyEvent) -> Bool)? = nil

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let textView = YAMLTextView()

        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false

        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.insertionPointColor = .labelColor
        textView.isRichText = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.typingAttributes = [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ]

        textView.delegate = context.coordinator
        let coordinator = context.coordinator
        textView.vimEngineProvider = { coordinator.parent?.vimEngine }
        textView.isShowingSlash = { !(coordinator.parent?.slashPrefix?.wrappedValue ?? "").isEmpty }
        textView.slashKeyHandler = { event in
            coordinator.parent?.onSlashKeyEvent?(event) ?? false
        }
        context.coordinator.textView = textView

        context.coordinator.setTextAndHighlight(text)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? YAMLTextView else { return }
        context.coordinator.parent = self

        if textView.string != text {
            context.coordinator.setTextAndHighlight(text)
        }

        // On vim→off transition, restore first responder and repaint the
        // cursor cell so the lingering block clears.
        let vimActiveNow = (vimEngine != nil)
        if context.coordinator.lastVimActive && !vimActiveNow {
            DispatchQueue.main.async {
                if let window = textView.window {
                    window.makeFirstResponder(textView)
                }
                textView.invalidateBlockCursorArea()
            }
        }
        context.coordinator.lastVimActive = vimActiveNow
    }

    func makeCoordinator() -> Coordinator {
        let c = Coordinator(text: $text)
        c.parent = self
        return c
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var parent: CodeEditorView?
        weak var textView: NSTextView?
        let highlighter = YAMLHighlighter()
        let completionProvider = YAMLCompletionProvider()
        private var isUpdating = false
        var lastVimActive = false

        private let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ]

        init(text: Binding<String>) {
            self.text = text
        }

        @MainActor func setTextAndHighlight(_ newText: String) {
            guard let textView else { return }
            isUpdating = true

            let selectedRanges = textView.selectedRanges
            textView.string = newText
            if let storage = textView.textStorage {
                highlighter.highlight(storage)
            }

            // Reset typing attributes so new text is default color
            textView.typingAttributes = baseAttrs

            let maxLen = newText.utf16.count
            let safeRanges = selectedRanges.compactMap { rangeValue -> NSValue? in
                let range = rangeValue.rangeValue
                return range.location <= maxLen ? rangeValue : nil
            }
            if !safeRanges.isEmpty {
                textView.selectedRanges = safeRanges
            }

            isUpdating = false
        }

        func textDidChange(_ notification: Notification) {
            guard !isUpdating, let textView = notification.object as? NSTextView else { return }
            isUpdating = true

            text.wrappedValue = textView.string

            // Re-highlight
            let selectedRanges = textView.selectedRanges
            if let storage = textView.textStorage {
                highlighter.highlight(storage)
            }
            textView.selectedRanges = selectedRanges

            // Reset typing attributes so next keystroke uses default color
            textView.typingAttributes = baseAttrs

            isUpdating = false

            // Slash-command detection
            if let parent, let binding = parent.slashPrefix {
                binding.wrappedValue = parent.vimEngine != nil
                    ? ""
                    : Coordinator.findSlashPrefix(in: textView)
            }
        }

        // MARK: - Completion

        func textView(_ textView: NSTextView, completions words: [String],
                       forPartialWordRange charRange: NSRange,
                       indexOfSelectedItem index: UnsafeMutablePointer<Int>?) -> [String] {
            let nsText = textView.string as NSString
            let cursorLocation = textView.selectedRange().location
            let lineRange = nsText.lineRange(for: NSRange(location: cursorLocation, length: 0))
            let line = nsText.substring(with: lineRange).trimmingCharacters(in: .newlines)

            let suggestions = completionProvider.completions(for: line, cursorPosition: cursorLocation - lineRange.location)
            if let index {
                index.pointee = 0  // Pre-select first item
            }
            return suggestions
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if parent?.vimEngine != nil { return false }

            // Tab: insert 2 spaces (YAML indent) or trigger completion if line has content
            if commandSelector == #selector(NSResponder.insertTab(_:)) {
                let nsText = textView.string as NSString
                let cursorLocation = textView.selectedRange().location
                let lineRange = nsText.lineRange(for: NSRange(location: cursorLocation, length: 0))
                let line = nsText.substring(with: lineRange).trimmingCharacters(in: .newlines)
                let lineToCursor = nsText.substring(
                    with: NSRange(location: lineRange.location,
                                  length: cursorLocation - lineRange.location))

                if line.trimmingCharacters(in: .whitespaces).isEmpty {
                    let cursorOffsetInLine = cursorLocation - lineRange.location
                    let suggestions = completionProvider.completions(
                        for: line, cursorPosition: cursorOffsetInLine)
                    if suggestions.isEmpty {
                        textView.insertText("  ", replacementRange: textView.selectedRange())
                    } else {
                        textView.complete(nil)
                    }
                } else if lineToCursor.hasSuffix(":") {
                    textView.insertText(" ", replacementRange: textView.selectedRange())
                    textView.complete(nil)
                } else {
                    textView.complete(nil)
                }
                return true
            }

            // Auto-indent on newline
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                let nsText = textView.string as NSString
                let selectedRange = textView.selectedRange()
                let lineRange = nsText.lineRange(for: NSRange(location: selectedRange.location, length: 0))
                let currentLine = nsText.substring(with: lineRange)

                let indent = currentLine.prefix(while: { $0 == " " })
                var newIndent = String(indent)

                let trimmed = currentLine.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasSuffix(":") {
                    newIndent += "  "
                }

                textView.insertNewline(nil)
                textView.insertText(newIndent, replacementRange: textView.selectedRange())
                return true
            }

            return false
        }

        /// Walk back from the caret looking for the start of a
        /// slash-command token (`/<alphanum/-/_>*`).
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

/// NSTextView subclass that scopes completion's partial-word range to a token.
final class YAMLTextView: VimHostTextView {
    private static let wordChars = CharacterSet.alphanumerics
        .union(CharacterSet(charactersIn: "_-."))

    override var rangeForUserCompletion: NSRange {
        let nsText = string as NSString
        let cursor = selectedRange().location

        var start = cursor
        while start > 0 {
            let c = Character(UnicodeScalar(nsText.character(at: start - 1))!)
            if c.unicodeScalars.allSatisfy({ Self.wordChars.contains($0) }) {
                start -= 1
            } else {
                break
            }
        }

        return NSRange(location: start, length: cursor - start)
    }
}
