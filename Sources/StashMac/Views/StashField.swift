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
    @Binding var text: String
    /// Heights for the unfocused and focused states. Set
    /// `focusedHeight` larger than `idleHeight` to get the
    /// "expand-when-you-click-into-it" effect — useful for fields
    /// like Notes where the user might want a bigger workspace
    /// while editing. Default behaviour (both nil) leaves layout
    /// entirely up to the caller via `.frame(minHeight:)`.
    var idleHeight: CGFloat? = nil
    var focusedHeight: CGFloat? = nil
    @FocusState private var isFocused: Bool

    var body: some View {
        let activeHeight = isFocused ? (focusedHeight ?? idleHeight) : idleHeight
        TextEditor(text: $text)
            .font(.body)
            .scrollContentBackground(.hidden)
            .padding(4)
            .frame(minHeight: activeHeight)
            .background(isFocused ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isFocused ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.1), lineWidth: 1)
            )
            .focused($isFocused)
            .animation(.easeInOut(duration: 0.18), value: isFocused)
    }
}
