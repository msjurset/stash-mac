import SwiftUI

struct StashField: View {
    let label: String
    @Binding var text: String
    var prompt: String = ""
    var onSubmit: (() -> Void)?
    @State private var isFocused = false

    init(_ label: String, text: Binding<String>, prompt: String = "", onSubmit: (() -> Void)? = nil) {
        self.label = label
        self._text = text
        self.prompt = prompt
        self.onSubmit = onSubmit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            FilterField(
                placeholder: prompt,
                text: $text,
                onSubmit: onSubmit,
                onBeginEditing: { isFocused = true },
                onEndEditing: { isFocused = false }
            )
            .padding(8)
            .background(isFocused ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isFocused ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.1), lineWidth: 1)
            )
            .animation(.easeInOut(duration: 0.15), value: isFocused)
        }
    }
}

struct StashTextEditor: View {
    var itemID: String? = nil
    @Binding var text: String
    /// Heights for the unfocused and focused states. Set
    /// `focusedHeight` larger than `idleHeight` to get the
    /// "expand-when-you-click-into-it" effect — useful for fields
    /// like Notes where the user might want a bigger workspace
    /// while editing. Default behaviour (both nil) leaves layout
    /// entirely up to the caller via `.frame(minHeight:)`.
    var idleHeight: CGFloat? = nil
    var focusedHeight: CGFloat? = nil
    var monospaced: Bool = false
    var onAction: ((ActionCommand) -> Void)? = nil
    @State private var isFocused: Bool = false

    var body: some View {
        let activeHeight = isFocused ? (focusedHeight ?? idleHeight) : idleHeight
        // Backed by VimAwareEditor so `/vim` activates vim
        // keybindings in any place StashTextEditor renders —
        // EditItemSheet Notes / Extracted Text, AddItemSheet snippet,
        // RuleDetailView rule body. Visual chrome (background,
        // accent overlay, focus ring) is layered on top of the
        // host editor's transparent body. Focus tracking comes back
        // through onFocusChanged since @FocusState doesn't see the
        // underlying NSTextView.
        //
        // Badge placement: .bottomFooter renders a vim-style status
        // line inside the field's rounded clip when vim is active.
        // The line shows the mode badge (VIM:N / VIM:I / :q / /term)
        // on the left and a cheatsheet + close button pair on the
        // right. The previous top-right overlay collided with text
        // in wider editors; the footer stays clear of the content.
        VimAwareEditor(
            itemID: itemID,
            text: $text,
            onAction: onAction,
            onFocusChanged: { focused in
                withAnimation(.easeInOut(duration: 0.18)) {
                    isFocused = focused
                }
            },
            badgePlacement: .bottomFooter,
            font: .systemFont(ofSize: 13),
            textContainerInset: NSSize(width: 4, height: 4),
            drawsBackground: false,
            monospaced: monospaced
        )
        .frame(minHeight: activeHeight)
        .background(isFocused ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isFocused ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.1), lineWidth: 1)
        )
    }
}
