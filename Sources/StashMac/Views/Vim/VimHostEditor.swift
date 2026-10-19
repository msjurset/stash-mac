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

    /// caller-supplied handler for double clicks on whitespace.
    var onDoubleClickWhitespace: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = VimEditorScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = drawsBackground
        if drawsBackground { scrollView.backgroundColor = backgroundColor }

        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)

        let containerSize = NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude)
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
        tv.isEditable = true
        tv.isSelectable = true
        tv.isRichText = false
        tv.allowsUndo = true
        tv.disableAutoFeatures()
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
        tv.onDoubleClickWhitespace = { coordinator.parent.onDoubleClickWhitespace?() }
        tv.onFirstResponderChanged = { focused in coordinator.parent.onFocusChanged?(focused) }
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

        let contentWidth = scrollView.contentSize.width
        if contentWidth > 0 {
            if tv.frame.size.width != contentWidth {
                tv.frame.size.width = contentWidth
            }
            if let tc = tv.textContainer, tc.containerSize.width != contentWidth {
                tc.containerSize = NSSize(width: contentWidth, height: .greatestFiniteMagnitude)
            }
        }

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
            DispatchQueue.main.async {
                self.pendingCursor = nil
            }
            let length = (tv.string as NSString).length
            let clamped = max(0, min(cursor, length))
            tv.setSelectedRange(NSRange(location: clamped, length: 0))
            if let window = tv.window {
                DispatchQueue.main.async {
                    if !window.isKeyWindow {
                        window.makeKeyAndOrderFront(nil)
                    }
                    window.makeFirstResponder(tv)
                }
            } else {
                tv.focusOnWindowArrival = true
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



        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                return handleNewline(in: textView)
            } else if commandSelector == #selector(NSResponder.deleteBackward(_:)) {
                let handled = handleDeleteBackward(in: textView)
                if !handled {
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self, let tv = self.textView else { return }
                        self.renumberListsAroundCursor(in: tv)
                    }
                }
                return handled
            } else if commandSelector == #selector(NSResponder.insertTab(_:)) {
                if parent.currentMode == .vim {
                    return false
                }
                let spaces = "  "
                let range = textView.selectedRange()
                if textView.shouldChangeText(in: range, replacementString: spaces) {
                    textView.textStorage?.replaceCharacters(in: range, with: spaces)
                    textView.didChangeText()
                    textView.setSelectedRange(NSRange(location: range.location + spaces.utf16.count, length: 0))
                }
                return true
            } else if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
                if parent.currentMode == .vim {
                    return false
                }
                let nsString = textView.string as NSString
                let cursor = textView.selectedRange().location
                if cursor >= 2 && nsString.substring(with: NSRange(location: cursor - 2, length: 2)) == "  " {
                    let range = NSRange(location: cursor - 2, length: 2)
                    if textView.shouldChangeText(in: range, replacementString: "") {
                        textView.textStorage?.replaceCharacters(in: range, with: "")
                        textView.didChangeText()
                        textView.setSelectedRange(NSRange(location: cursor - 2, length: 0))
                    }
                    return true
                }
                return false
            }
            return false
        }

        @MainActor
        private func handleNewline(in textView: NSTextView) -> Bool {
            let nsString = textView.string as NSString
            let selection = textView.selectedRange()
            guard selection.length == 0 else { return false }

            let lineRange = nsString.lineRange(for: NSRange(location: selection.location, length: 0))
            let line = nsString.substring(with: lineRange)
            let lineNoNewline = line.hasSuffix("\n") ? String(line.dropLast()) : line

            let indent = String(lineNoNewline.prefix(while: { $0 == " " || $0 == "\t" }))
            let bodyAfterIndent = String(lineNoNewline.dropFirst(indent.count))

            guard let kind = ListPrefix.detect(in: bodyAfterIndent) else { return false }

            let prefixEnd = lineRange.location + (indent as NSString).length + kind.prefixLength
            guard selection.location >= prefixEnd else { return false }

            let trailing = String(bodyAfterIndent.dropFirst(kind.prefixLength))

            if trailing.isEmpty {
                if indent.count >= 2 {
                    let newIndent = String(indent.dropLast(2))
                    let replacement = newIndent + kind.continuation(indent: "")
                    let replaceRange = NSRange(location: lineRange.location, length: lineNoNewline.utf16.count)
                    guard textView.shouldChangeText(in: replaceRange, replacementString: replacement) else { return false }
                    textView.textStorage?.replaceCharacters(in: replaceRange, with: replacement)
                    textView.didChangeText()
                    let newCaret = lineRange.location + (replacement as NSString).length
                    textView.setSelectedRange(NSRange(location: newCaret, length: 0))
                    if case .ordered = kind {
                        renumberListsAroundCursor(in: textView)
                    }
                } else {
                    let suffix = "\n"
                    let replaceRange = lineRange
                    guard textView.shouldChangeText(in: replaceRange, replacementString: suffix) else { return false }
                    textView.textStorage?.replaceCharacters(in: replaceRange, with: suffix)
                    textView.didChangeText()
                    let newCaret = lineRange.location + (suffix as NSString).length
                    textView.setSelectedRange(NSRange(location: newCaret, length: 0))
                    renumberListsAroundCursor(in: textView)
                }
                return true
            }

            let insertion = "\n" + kind.continuation(indent: indent)
            let insertRange = NSRange(location: selection.location, length: 0)
            guard textView.shouldChangeText(in: insertRange, replacementString: insertion) else { return false }
            textView.textStorage?.replaceCharacters(in: insertRange, with: insertion)
            textView.didChangeText()
            let newCaret = selection.location + (insertion as NSString).length
            textView.setSelectedRange(NSRange(location: newCaret, length: 0))

            if case .ordered = kind {
                renumberListsAroundCursor(in: textView)
            }
            return true
        }

        @MainActor
        private func handleDeleteBackward(in textView: NSTextView) -> Bool {
            let nsString = textView.string as NSString
            let selection = textView.selectedRange()
            guard selection.length == 0 else { return false }

            let lineRange = nsString.lineRange(for: NSRange(location: selection.location, length: 0))
            let line = nsString.substring(with: lineRange)
            let lineNoNewline = line.hasSuffix("\n") ? String(line.dropLast()) : line
            let indent = String(lineNoNewline.prefix(while: { $0 == " " || $0 == "\t" }))
            let bodyAfterIndent = String(lineNoNewline.dropFirst(indent.count))

            if let kind = ListPrefix.detect(in: bodyAfterIndent) {
                let prefixEnd = lineRange.location + (indent as NSString).length + kind.prefixLength
                if selection.location == prefixEnd && String(bodyAfterIndent.dropFirst(kind.prefixLength)).isEmpty {
                    if indent.count >= 2 {
                        let newIndent = String(indent.dropLast(2))
                        let replacement = newIndent + kind.continuation(indent: "")
                        let replaceRange = NSRange(location: lineRange.location, length: lineNoNewline.utf16.count)
                        guard textView.shouldChangeText(in: replaceRange, replacementString: replacement) else { return false }
                        textView.textStorage?.replaceCharacters(in: replaceRange, with: replacement)
                        textView.didChangeText()
                        let newCaret = lineRange.location + (replacement as NSString).length
                        textView.setSelectedRange(NSRange(location: newCaret, length: 0))
                        if case .ordered = kind {
                            renumberListsAroundCursor(in: textView)
                        }
                    } else {
                        let replaceRange = NSRange(location: lineRange.location, length: lineNoNewline.utf16.count)
                        guard textView.shouldChangeText(in: replaceRange, replacementString: "") else { return false }
                        textView.textStorage?.replaceCharacters(in: replaceRange, with: "")
                        textView.didChangeText()
                        textView.setSelectedRange(NSRange(location: lineRange.location, length: 0))
                        renumberListsAroundCursor(in: textView)
                    }
                    return true
                }
            }
            return false
        }

        @MainActor
        private func renumberListsAroundCursor(in textView: NSTextView) {
            let text = textView.string as NSString
            let selection = textView.selectedRange()
            guard selection.location != NSNotFound && selection.location <= text.length else { return }
            let searchStart = text.lineRange(for: NSRange(location: selection.location, length: 0)).location
            
            var blockStart = searchStart
            while blockStart > 0 {
                let prevLineRange = text.lineRange(for: NSRange(location: blockStart - 1, length: 0))
                let prevLine = text.substring(with: prevLineRange)
                if prevLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }
                let indent = String(prevLine.prefix(while: { $0 == " " || $0 == "\t" }))
                let body = String(prevLine.dropFirst(indent.count))
                if let kind = ListPrefix.detect(in: body), case .ordered = kind {
                    blockStart = prevLineRange.location
                } else {
                    break
                }
            }
            
            var currentPos = blockStart
            var indentNumbers: [String: Int] = [:]
            
            while currentPos < text.length {
                let currentText = textView.string as NSString
                if currentPos >= currentText.length { break }
                let lineRange = currentText.lineRange(for: NSRange(location: currentPos, length: 0))
                let line = currentText.substring(with: lineRange)
                
                if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }
                
                let indent = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
                let body = String(line.dropFirst(indent.count))
                
                if let kind = ListPrefix.detect(in: body), case .ordered = kind {
                    let nextNum = indentNumbers[indent, default: 1]
                    let oldPrefixLength = kind.prefixLength
                    let newPrefix = "\(nextNum). "
                    
                    if body.prefix(oldPrefixLength) != newPrefix {
                        let replaceRange = NSRange(location: lineRange.location + indent.count, length: oldPrefixLength)
                        if textView.shouldChangeText(in: replaceRange, replacementString: newPrefix) {
                            textView.textStorage?.replaceCharacters(in: replaceRange, with: newPrefix)
                            textView.didChangeText()
                        }
                    }
                    indentNumbers[indent] = nextNum + 1
                    
                    let deeperIndents = indentNumbers.keys.filter { $0.count > indent.count && $0.hasPrefix(indent) }
                    for d in deeperIndents { indentNumbers.removeValue(forKey: d) }
                }
                
                let updatedText = textView.string as NSString
                let updatedLineRange = updatedText.lineRange(for: NSRange(location: currentPos, length: 0))
                currentPos = updatedLineRange.location + updatedLineRange.length
            }
        }

        /// Walk back from the caret looking for the start of a
        /// slash-command token (`/<alphanum/-/_>*`). Returns the
        /// full `/word` substring, or "" when there's no live
        /// slash context at the cursor.
        @MainActor
        static func findSlashPrefix(in tv: NSTextView) -> String {
            let selectedRange = tv.selectedRange()
            guard selectedRange.location != NSNotFound else { return "" }
            let cursorLocation = selectedRange.location
            let string = tv.string
            let nsString = string as NSString

            guard cursorLocation > 0, cursorLocation <= nsString.length else { return "" }

            var i = cursorLocation - 1
            while i >= 0 {
                let ch = nsString.character(at: i)
                if ch >= 0xD800 && ch <= 0xDFFF {
                    return ""
                }
                guard let scalar = Unicode.Scalar(ch) else { return "" }
                if scalar == "/" {
                    if i > 0 {
                        let prev = nsString.character(at: i - 1)
                        if prev >= 0xD800 && prev <= 0xDFFF {
                            return ""
                        }
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

/// List-prefix kinds the editor recognizes for smart continuation.
enum ListPrefix {
    case unordered(marker: Character)               // "-", "*", "+"
    case task(marker: Character, checked: Bool)     // "- [ ]" or "- [x]"
    case ordered(number: Int)                       // "1.", "23."
    case blockquote                                 // ">"

    var prefixLength: Int {
        switch self {
        case .unordered: return 2
        case .task: return 6
        case .ordered(let n): return String(n).count + 2
        case .blockquote: return 2
        }
    }

    func continuation(indent: String) -> String {
        switch self {
        case .unordered(let marker): return indent + "\(marker) "
        case .task(let marker, _): return indent + "\(marker) [ ] "
        case .ordered(let n): return indent + "\(n + 1). "
        case .blockquote: return indent + "> "
        }
    }

    static func detect(in body: String) -> ListPrefix? {
        let chars = Array(body)
        if chars.count >= 6, let marker = chars.first, "-*+–—".contains(marker),
           chars[1] == " ", chars[2] == "[", "xX ".contains(chars[3]),
           chars[4] == "]", chars[5] == " " {
            return .task(marker: marker, checked: chars[3].lowercased() == "x")
        }
        if chars.count >= 2, let marker = chars.first, "-*+–—".contains(marker), chars[1] == " " {
            return .unordered(marker: marker)
        }
        var digits = ""
        var i = 0
        while i < chars.count, chars[i].isASCII, chars[i].isNumber {
            digits.append(chars[i])
            i += 1
        }
        if !digits.isEmpty, i + 1 < chars.count, chars[i] == ".", chars[i + 1] == " ",
           let n = Int(digits) {
            return .ordered(number: n)
        }
        if body.hasPrefix("> ") { return .blockquote }
        return nil
    }
}

private class VimEditorScrollView: NSScrollView {
    override func tile() {
        super.tile()
        let contentWidth = contentSize.width
        let contentHeight = contentSize.height
        guard contentWidth > 0, let tv = documentView as? NSTextView else { return }
        if tv.frame.size.width != contentWidth {
            tv.frame.size.width = contentWidth
        }
        let layoutHeight = tv.layoutManager?.usedRect(for: tv.textContainer!).height ?? 0
        let targetHeight = max(contentHeight, layoutHeight + tv.textContainerInset.height * 2)
        if tv.frame.size.height != targetHeight {
            tv.frame.size.height = targetHeight
        }
        if tv.minSize.height != contentHeight {
            tv.minSize = NSSize(width: 0, height: contentHeight)
        }
        if let container = tv.textContainer, container.containerSize.width != contentWidth {
            container.containerSize = NSSize(width: contentWidth, height: .greatestFiniteMagnitude)
        }
    }
}
