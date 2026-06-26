import SwiftUI
import AppKit
import VimEngine

/// All-in-one editor container that wires CodeEditorView +
/// SlashSuggestionView + VimModeBadge into a single drop-in widget.
struct VimAwareCodeEditor: View {
    @Environment(StashStore.self) private var store
    @Binding var text: String
    var onSubmit: (() -> Void)? = nil
    var onAction: ((ActionCommand) -> Void)? = nil
    var onFocusChanged: ((Bool) -> Void)? = nil

    @State private var controller = VimModeController()
    @State private var slashPrefix: String = ""
    @State private var slashSelectedIndex: Int = 0

    private let registry = SlashCommandRegistry.shared

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                CodeEditorView(
                    text: $text,
                    vimEngine: controller.engine,
                    slashPrefix: $slashPrefix,
                    onSlashKeyEvent: handleSlashKey
                )
                VimModeBadge(controller: controller)
                    .padding(6)
            }

            // Vim status footer — only visible while vim is active.
            if controller.currentMode == .vim {
                VimStatusFooter(controller: controller)
            }

            // Slash suggestion dropdown
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
            if let cmd = registry.exactMatch(prefix: slashPrefix) {
                commit(cmd)
                return true
            }
            return false
        }
    }

    private func commit(_ command: SlashCommand) {
        guard !slashPrefix.isEmpty,
              let tv = (NSApp.keyWindow?.firstResponder as? YAMLTextView) else { return }

        // Strip the typed partial command at the caret
        let cursor = tv.selectedRange().location
        let ns = tv.string as NSString
        let partialCount = slashPrefix.count
        if cursor >= partialCount {
            let start = cursor - partialCount
            let range = NSRange(location: start, length: partialCount)
            
            if tv.shouldChangeText(in: range, replacementString: "") {
                tv.replaceCharacters(in: range, with: "")
                tv.didChangeText()
                tv.setSelectedRange(NSRange(location: start, length: 0))
            }
        }
        
        slashPrefix = ""
        
        switch command {
        case .mode(let modeCommand):
            if modeCommand.mode == .vim {
                controller.toggle()
            }
        case .inline(let transformCommand):
            let replacement = transformCommand.transform(tv.string)
            let cur = tv.selectedRange().location
            if tv.shouldChangeText(in: NSRange(location: cur, length: 0), replacementString: replacement) {
                tv.replaceCharacters(in: NSRange(location: cur, length: 0), with: replacement)
                tv.didChangeText()
                tv.setSelectedRange(NSRange(location: cur + replacement.utf16.count, length: 0))
            }
        case .field(let transformCommand):
            let newText = transformCommand.transform(tv.string)
            let range = NSRange(location: 0, length: ns.length - partialCount) // text length already reduced by partialCount
            if tv.shouldChangeText(in: range, replacementString: newText) {
                tv.replaceCharacters(in: range, with: newText)
                tv.didChangeText()
                tv.setSelectedRange(NSRange(location: 0, length: 0))
            }
        case .action(let actionCommand):
            onAction?(actionCommand)
        }
    }
}
