import SwiftUI

struct StashField: View {
    let label: String
    @Binding var text: String
    var prompt: String = ""
    var onSubmit: (() -> Void)?
    @FocusState private var isFocused: Bool

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
            TextField("", text: $text, prompt: prompt.isEmpty ? nil : Text(prompt))
                .textFieldStyle(.plain)
                .padding(8)
                .background(isFocused ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isFocused ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.1), lineWidth: 1)
                )
                .focused($isFocused)
                .onSubmit { onSubmit?() }
                .animation(.easeInOut(duration: 0.15), value: isFocused)
        }
    }
}

struct StashTextEditor: View {
    @Binding var text: String
    @FocusState private var isFocused: Bool

    var body: some View {
        TextEditor(text: $text)
            .font(.body)
            .scrollContentBackground(.hidden)
            .padding(4)
            .background(isFocused ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isFocused ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.1), lineWidth: 1)
            )
            .focused($isFocused)
            .animation(.easeInOut(duration: 0.15), value: isFocused)
    }
}
