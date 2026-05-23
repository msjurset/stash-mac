import AppKit
import VimEngine

/// The canonical NSTextView subclass for every multi-line text
/// editor in stash-mac. Holds the closures that wire vim and the
/// slash-command UX into AppKit:
///
///   - `vimEngineProvider` — returns the active VimEngine, or nil
///     when the editor is in plain typing mode.
///   - `isShowingSlash` — true while the suggestion dropdown is
///     visible; used by the keyDown switch to intercept navigation
///     keys (↑/↓/Tab/Enter/Esc/Space) before they reach AppKit.
///   - `slashKeyHandler` — caller-provided handler for those
///     intercepted keys; returns true if it consumed the event.
///   - `submitHandler` — Cmd+Enter "save and dismiss" hook.
///
/// All vim-related overrides (keyDown, drawInsertionPoint,
/// setSelectedRanges, insertText for R-mode overstrike) live here.
/// Don't fork this class into per-editor subclasses; pass options
/// in via VimHostEditor's parameters instead.
final class VimHostTextView: NSTextView {

    /// Live VimEngine when vim is active in this editor's host
    /// view. Nil otherwise. Closure rather than stored reference so
    /// SwiftUI state changes flow through without re-binding the
    /// text view.
    var vimEngineProvider: (() -> VimEngine?)?

    /// Closure that returns the active EditorMode. Used for mode-based
    /// character transforms (like .uppercase).
    var currentModeProvider: (() -> EditorMode?)?

    /// True when the slash-command suggestion dropdown is open.
    /// Keydown switch consults this before forwarding nav keys to
    /// the slash handler.
    var isShowingSlash: (() -> Bool)?

    /// Caller-supplied handler for slash-suggestion navigation
    /// keys. Returns true if the event was consumed (don't pass to
    /// super), false to let normal text input happen.
    var slashKeyHandler: ((SlashKeyEvent) -> Bool)?

    /// Cmd+Enter dispatcher — surfaces "save / commit" intent to
    /// the caller. nil means "no submit action wired" and the key
    /// falls through to default behavior.
    var submitHandler: (() -> Void)?

    enum SlashKeyEvent {
        case arrowLeft, arrowRight, enter, escape, tab, space
    }

    // MARK: - Block cursor

    /// Translucent block cursor, drawn behind the glyph when vim is
    /// in any non-insert submode. Falls back to AppKit's beam when
    /// vim isn't active or is in insert mode (where typing happens
    /// at a caret position, not over a cell).
    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        guard let vim = vimEngineProvider?(), vim.submode != .insert else {
            super.drawInsertionPoint(in: rect, color: color, turnedOn: flag)
            return
        }
        guard flag, let block = blockCursorRect() else { return }
        NSColor.selectedTextBackgroundColor.withAlphaComponent(0.75).setFill()
        block.fill()
    }

    /// Force a full repaint of the text-view content. Called on
    /// vim mode transitions (insert→normal, etc.) so the cursor
    /// shape flips immediately. We DO NOT compute partial old/new
    /// cursor rects — under load AppKit coalesces those, leaving a
    /// "double cursor" ghost behind. Full invalidate is cheap on
    /// editor-sized text views and reliable.
    func invalidateBlockCursorArea() {
        needsDisplay = true
    }

    /// Compute the screen rect to fill for the block cursor.
    /// Handles three cases: empty buffer (paint at containerOrigin),
    /// caret past last glyph (synthesize a cell), and normal in-line
    /// position (use the glyph's bounding rect, narrowed to a char
    /// width when the layout manager returns a full-line rect for a
    /// newline / EOL).
    private func blockCursorRect() -> NSRect? {
        guard let layoutManager, let textContainer else { return nil }
        let ns = string as NSString
        let cursor = selectedRange.location

        if cursor >= ns.length {
            let lineHeight = font?.boundingRectForFont.height ?? 16
            if ns.length == 0 {
                let origin = textContainerOrigin
                return NSRect(x: origin.x, y: origin.y, width: 8, height: lineHeight)
            }
            let lastRange = NSRange(location: ns.length - 1, length: 1)
            let glyphRange = layoutManager.glyphRange(forCharacterRange: lastRange, actualCharacterRange: nil)
            let lastRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            return NSRect(
                x: lastRect.maxX + textContainerOrigin.x,
                y: lastRect.minY + textContainerOrigin.y,
                width: max(lastRect.width, 8),
                height: lastRect.height
            )
        }

        let range = NSRange(location: cursor, length: 1)
        let chAtCursor = ns.character(at: cursor)
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var r = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        r.origin.x += textContainerOrigin.x
        r.origin.y += textContainerOrigin.y

        if chAtCursor == 0x0A {
            r.size.width = approximateCharWidth()
        } else if r.width <= 1 {
            r.size.width = approximateCharWidth()
        }
        return r
    }

    private func approximateCharWidth() -> CGFloat {
        guard let font else { return 8 }
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let size = ("M" as NSString).size(withAttributes: attributes)
        return size.width > 0 ? size.width : 8
    }

    // MARK: - Selection / scroll integration

    /// Two responsibilities here: scroll caret into view after a
    /// vim-driven move (AppKit's auto-scroll only fires on
    /// insertText, which vim bypasses), and repaint the block
    /// cursor cell after vim moves the caret.
    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)

        guard let vim = vimEngineProvider?() else { return }

        if !stillSelecting, let primary = ranges.first?.rangeValue {
            // Zero-length range — we want the caret visible, not the
            // far end of a multi-screen visual selection.
            scrollRangeToVisible(NSRange(location: primary.location, length: 0))
        }

        if vim.submode != .insert {
            needsDisplay = true
        }
    }

    // MARK: - Replace-mode (R) overstrike

    /// When vim's submode is .replace (entered via R in normal),
    /// typing should OVERWRITE the character under the caret
    /// rather than insert. The insertText override checks vim's
    /// state and routes to overwriteText when appropriate.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        var processedString = string
        if let s = string as? String, currentModeProvider?() == .uppercase {
            processedString = s.uppercased()
        }

        if let vim = vimEngineProvider?(), vim.submode == .replace,
           let s = processedString as? String {
            overwriteText(s)
            return
        }
        super.insertText(processedString, replacementRange: replacementRange)
    }

    private func overwriteText(_ s: String) {
        let ns = self.string as NSString
        let cursor = selectedRange.location
        // Don't overstrike newlines or extend past EOF — match
        // standard vim R behavior of inserting at line breaks.
        let canOverwrite = cursor < ns.length && ns.character(at: cursor) != 0x0A
        let range = canOverwrite
            ? NSRange(location: cursor, length: 1)
            : NSRange(location: cursor, length: 0)
        if shouldChangeText(in: range, replacementString: s) {
            replaceCharacters(in: range, with: s)
            didChangeText()
            let newLoc = cursor + (s as NSString).length
            setSelectedRange(NSRange(location: newLoc, length: 0))
        }
    }

    // MARK: - Cmd-shortcut passthrough

    /// Standard Cmd shortcuts still work while vim is active —
    /// they go through performKeyEquivalent before keyDown, so
    /// vim's keyDown handler never sees them.
    ///
    /// **Must gate on first responder.** performKeyEquivalent
    /// walks the entire view hierarchy and the first view that
    /// returns true consumes the event. Without this guard, a
    /// Cmd+V pressed in a *different* text field (e.g. the Title
    /// FilterField in EditItemSheet) gets hijacked by whichever
    /// VimHostTextView happens to be in the same window — paste
    /// fires on the wrong target and the user's actual focused
    /// field gets nothing. Same trap for Cmd+C / Cmd+X / Cmd+A.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isCurrentFirstResponder, event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers {
            case "v": pasteAsPlainText(nil); return true
            case "c": copy(nil); return true
            case "x": cut(nil); return true
            case "a": selectAll(nil); return true
            case "z":
                if event.modifierFlags.contains(.shift) {
                    undoManager?.redo()
                } else {
                    undoManager?.undo()
                }
                return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    /// True when this text view (via its field editor) actually owns
    /// keyboard focus in its window. NSTextView's `firstResponder`
    /// for an editable text view is typically the view itself.
    private var isCurrentFirstResponder: Bool {
        guard let fr = window?.firstResponder else { return false }
        if fr === self { return true }
        // NSTextView sometimes installs its layoutManager's field
        // editor as first responder; check delegate ownership too.
        if let text = fr as? NSText, text.delegate === self { return true }
        return false
    }

    // MARK: - keyDown — vim arbiter + slash interceptor

    /// Three layers: Cmd+Enter for submit, vim engine if active,
    /// slash-suggestion nav keys if the dropdown is open, then
    /// finally falls through to AppKit's default behavior. The
    /// order matters: vim owns the keyboard once active, but
    /// Cmd-shortcuts above always win because they're routed via
    /// performKeyEquivalent before keyDown fires.
    override func keyDown(with event: NSEvent) {
        // Cmd+Enter → submit handler (save / commit shape).
        if event.modifierFlags.contains(.command), event.keyCode == 36 {
            submitHandler?()
            return
        }

        if let vim = vimEngineProvider?() {
            let prevSubmode = vim.submode
            let handled = vim.handleKey(
                chars: event.charactersIgnoringModifiers,
                keyCode: event.keyCode,
                modifiers: KeyModifiers(event.modifierFlags),
                editor: self
            )
            if handled {
                if prevSubmode != vim.submode {
                    invalidateBlockCursorArea()
                }
                return
            }
        }

        if isShowingSlash?() == true {
            switch event.keyCode {
            case 123: if slashKeyHandler?(.arrowLeft)  == true { return }
            case 124: if slashKeyHandler?(.arrowRight) == true { return }
            case 36:  if slashKeyHandler?(.enter)     == true { return }
            case 48:  if slashKeyHandler?(.tab)       == true { return }
            case 53:  if slashKeyHandler?(.escape)    == true { return }
            case 49:  if slashKeyHandler?(.space)     == true { return }
            default: break
            }
        }

        super.keyDown(with: event)
    }
}
