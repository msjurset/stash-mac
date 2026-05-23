import SwiftUI
import AppKit
import VimEngine

/// All-in-one editor container that wires VimHostEditor +
/// SlashSuggestionView + VimModeBadge into a single drop-in widget.
/// Call sites pass the text binding and the visual configuration;
/// this view handles the slash command lifecycle internally.
///
/// Use this in place of TextEditor / TransparentTextEditor /
/// NotesTextEditor for any multi-line editing surface that should
/// support `/vim` activation.
///
/// **What the caller controls:**
///   - `text` binding (mandatory)
///   - `onSubmit` (optional — fires on Cmd+Enter or vim's `:w`)
///   - Visual config: font, container inset, opaque vs transparent
///     background, monospaced flag
///
/// **What this view owns internally:**
///   - The VimModeController (one per instance)
///   - The slash prefix + suggestion-index state
///   - The pending-cursor state for the editor
///   - The mode badge and cheatsheet UI
struct VimAwareEditor: View {
    @Environment(StashStore.self) private var store
    let itemID: String?
    @Binding var text: String
    var onSubmit: (() -> Void)? = nil
    var onAction: ((ActionCommand) -> Void)? = nil
    var onFocusChanged: ((Bool) -> Void)? = nil

    /// When the parent wants to render the mode badge / activate
    /// button in its own chrome (e.g. a popover header with a
    /// title + "Click away to save"), it passes its own controller
    /// here and sets `badgePlacement: .external`. Default nil = the
    /// editor owns the controller internally and shows the badge
    /// per `badgePlacement`.
    var externalController: VimModeController? = nil

    /// Where to render the in-editor mode badge.
    ///
    /// - `.topRightOverlay`: float in the upper-right corner via
    ///   ZStack. The original placement; works in editors with
    ///   enough horizontal whitespace.
    /// - `.bottomFooter`: persistent footer strip pinned to the
    ///   bottom of the editor, only visible while vim is active.
    ///   Vim-style status line — same pattern as vim's own
    ///   bottom-line mode indicator. Doesn't compete with text.
    /// - `.external`: don't render at all. Parent owns the badge
    ///   placement (header, sheet toolbar, etc.) using the
    ///   `externalController` it passed in.
    var badgePlacement: VimBadgePlacement = .topRightOverlay

    // Visual config — pass through to VimHostEditor.
    var font: NSFont = .systemFont(ofSize: 13)
    var textContainerInset: NSSize = NSSize(width: 8, height: 8)
    var drawsBackground: Bool = true
    var backgroundColor: NSColor = .textBackgroundColor
    var monospaced: Bool = false

    @State private var internalController = VimModeController()
    @State private var slashPrefix: String = ""
    @State private var slashSelectedIndex: Int = 0
    @State private var pendingCursor: Int? = nil

    private var controller: VimModeController {
        externalController ?? internalController
    }

    private let registry = SlashCommandRegistry.shared

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                VimHostEditor(
                    text: $text,
                    slashPrefix: $slashPrefix,
                    pendingCursor: $pendingCursor,
                    currentMode: controller.currentMode,
                    vimEngine: controller.engine,
                    font: font,
                    textContainerInset: textContainerInset,
                    drawsBackground: drawsBackground,
                    backgroundColor: backgroundColor,
                    monospaced: monospaced,
                    onSubmit: onSubmit,
                    onSlashKeyEvent: handleSlashKey,
                    onFocusChanged: onFocusChanged
                )
                if badgePlacement == .topRightOverlay {
                    VimModeBadge(controller: controller)
                        .padding(6)
                }
            }

            // Vim status footer — only when placement is .bottomFooter
            // AND vim is active. Pinned below the editor's text area
            // and renders inside the editor's outer rounded clip
            // (the caller's .clipShape happens after this VStack).
            if badgePlacement == .bottomFooter && controller.currentMode == .vim {
                VimStatusFooter(controller: controller)
            }

            // Slash suggestion dropdown — only renders when there's
            // a live `/<word>` prefix at the caret.
            if !slashPrefix.isEmpty {
                SlashSuggestionView(
                    commands: registry.all,
                    filter: slashPrefix,
                    selectedIndex: $slashSelectedIndex
                )
            }
        }
        .onChange(of: slashPrefix) { _, _ in
            slashSelectedIndex = 0
        }
        .onAppear {
            controller.onSubmit = onSubmit
        }
        .onChange(of: onSubmit == nil) { _, _ in
            controller.onSubmit = onSubmit
        }
    }

    private func handleSlashKey(_ event: VimHostTextView.SlashKeyEvent) -> Bool {
        let items = registry.match(prefix: slashPrefix)

        switch event {
        case .arrowRight:
            guard !items.isEmpty else { return false }
            slashSelectedIndex = min(slashSelectedIndex + 1, items.count - 1)
            return true
        case .arrowLeft:
            guard !items.isEmpty else { return false }
            slashSelectedIndex = max(slashSelectedIndex - 1, 0)
            return true
        case .enter, .tab:
            guard !items.isEmpty else { return false }
            commit(items[slashSelectedIndex])
            return true
        case .escape:
            slashPrefix = ""
            return true
        case .space:
            // Space commits only on an exact name match; otherwise
            // it falls through and naturally ends the slash context.
            if let cmd = registry.exactMatch(prefix: slashPrefix) {
                commit(cmd)
                return true
            }
            return false
        }
    }

    /// Strip the `/<word>` prefix from the text and run the chosen
    /// command. For mode commands we toggle: typing `/vim` again
    /// while vim is on exits cleanly.
    private func commit(_ command: SlashCommand) {
        guard !slashPrefix.isEmpty,
              let range = text.range(of: slashPrefix, options: .backwards) else { return }
        let prefixStartUTF16 = text.utf16.distance(
            from: text.utf16.startIndex,
            to: range.lowerBound.samePosition(in: text.utf16) ?? text.utf16.startIndex
        )

        switch command {
        case .mode(let modeCommand):
            text.replaceSubrange(range, with: "")
            pendingCursor = prefixStartUTF16
            
            if modeCommand.mode == .vim {
                if controller.currentMode == .vim {
                    controller.exit()
                } else {
                    controller.activate()
                }
            } else {
                // Toggle other modes (like uppercase)
                if internalController.currentMode == modeCommand.mode {
                    internalController.currentMode = nil
                } else {
                    internalController.currentMode = modeCommand.mode
                }
            }
        case .inline(let transformCommand):
            // Inline replacement of the command token itself
            let replacement = transformCommand.transform(text)
            text.replaceSubrange(range, with: replacement)
            pendingCursor = prefixStartUTF16 + replacement.utf16.count
        case .field(let transformCommand):
            // Strip the command first, then transform the entire field.
            let remainder = text.replacingCharacters(in: range, with: "")
            text = transformCommand.transform(remainder)
            // Field transforms usually reset cursor to start or end;
            // let's stick to start or preserve approximate position.
            pendingCursor = 0
        case .action(let actionCommand):
            text.replaceSubrange(range, with: "")
            pendingCursor = prefixStartUTF16
            
            // Item-specific AI transforms
            if let itemID {
                if actionCommand.name == "fix" {
                    store.fixSpelling(itemID: itemID, text: text)
                } else if actionCommand.name == "sum" {
                    store.summarize(itemID: itemID, text: text)
                } else if actionCommand.name == "tags" {
                    store.suggestTags(itemID: itemID, text: text)
                } else {
                    onAction?(actionCommand)
                }
            } else {
                onAction?(actionCommand)
            }
        }
        slashPrefix = ""
    }
}
