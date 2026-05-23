import SwiftUI

/// Inline pill-row dropdown shown beneath a VimHostEditor while the
/// user is typing `/<partial>`. Ported from jrnlbar's
/// SlashSuggestionView with the same keyboard nav contract:
/// arrow keys / Tab move the highlight, Enter commits.
struct SlashSuggestionView: View {
    let commands: [SlashCommand]
    let filter: String
    @Binding var selectedIndex: Int

    var filteredCommands: [SlashCommand] {
        var needle = filter
        while needle.hasPrefix("/") { needle.removeFirst() }
        let lower = needle.lowercased()
        if lower.isEmpty {
            return commands
        }
        return commands.filter { $0.name.lowercased().hasPrefix(lower) }
    }

    var body: some View {
        let items = filteredCommands
        if !items.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "slash.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, command in
                                pill(command: command, index: index)
                                    .id(index)
                            }
                        }
                        .padding(.vertical, 1)
                    }
                    .onChange(of: selectedIndex) { _, newIndex in
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(newIndex, anchor: .center)
                        }
                    }
                }

                Text("←→ Enter")
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
                    .layoutPriority(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.03))
        }
    }

    @ViewBuilder
    private func pill(command: SlashCommand, index: Int) -> some View {
        HStack(spacing: 4) {
            Text("/\(command.name)")
                .font(.caption)
                .fontWeight(.medium)
            if !command.hint.isEmpty {
                Text(command.hint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            index == selectedIndex
                ? Color.accentColor.opacity(0.3)
                : Color.primary.opacity(0.06)
        )
        .clipShape(Capsule())
        .onTapGesture {
            selectedIndex = index
        }
    }
}
