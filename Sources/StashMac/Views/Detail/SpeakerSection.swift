import SwiftUI

struct SpeakerSection: View {
    @Environment(StashStore.self) private var store
    let item: StashItem
    
    @State private var editingSpeakerID: String? = nil
    @State private var nameDraft: String = ""
    
    private var speakerIDs: [String] {
        guard let text = item.extractedText else { return [] }
        let patterns = ["#### SPEAKER (\\d+)", "(?m)^SPEAKER (\\d+):"]
        var ids = Set<String>()
        
        for pattern in patterns {
            let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
            let matches = regex?.matches(in: text, options: [], range: nsRange) ?? []
            
            for match in matches {
                if match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) {
                    ids.insert(String(text[range]))
                }
            }
        }
        return Array(ids).sorted()
    }
    
    var body: some View {
        if !speakerIDs.isEmpty {
            DetailSection(title: "Speakers") {
                FlowLayout(spacing: 8) {
                    ForEach(speakerIDs, id: \.self) { id in
                        speakerPill(id: id)
                    }
                }
            }
        }
    }
    
    @ViewBuilder
    private func speakerPill(id: String) -> some View {
        let name = item.speakerMap?[id] ?? "Speaker \(id)"
        let color = colorForID(id)
        
        HStack(spacing: 4) {
            if editingSpeakerID == id {
                FilterField(
                    placeholder: "Name",
                    text: $nameDraft,
                    font: .preferredFont(forTextStyle: .callout),
                    autoFocus: true,
                    onSubmit: { commitRename(id: id) },
                    onKey: { key in
                        if key == .escape {
                            editingSpeakerID = nil
                            return true
                        }
                        return false
                    }
                )
                .frame(width: 100)
                .onAppear { nameDraft = name }
                
                Button {
                    commitRename(id: id)
                } label: {
                    Image(systemName: "checkmark")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                
                Button {
                    editingSpeakerID = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
            } else {
                Text(name)
                    .font(.callout.bold())
                
                Image(systemName: "pencil")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(color.opacity(0.2))
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .strokeBorder(color.opacity(0.5), lineWidth: 1)
        )
        .onTapGesture {
            if editingSpeakerID == nil {
                editingSpeakerID = id
                nameDraft = name
            }
        }
    }
    
    private func colorForID(_ id: String) -> Color {
        let colors: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .indigo, .yellow]
        if let idx = Int(id) {
            return colors[(idx - 1) % colors.count]
        }
        return .gray
    }
    
    private func commitRename(id: String) {
        var newMap = item.speakerMap ?? [:]
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            newMap[id] = trimmed
            store.editItem(id: item.id, speakerMap: newMap)
        }
        editingSpeakerID = nil
    }
}
