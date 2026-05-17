import SwiftUI

/// Picker sheet for the multi-select "Merge…" action. Renders the
/// selected items as a radio group: the choice becomes the target
/// (keeper), every other selected item becomes a source whose
/// primary file folds into the target's carousel.
///
/// Confirmation shape mirrors the design doc — clearly shows what
/// will happen to title / notes / tags / files before commit.
struct MergeItemsSheet: View {
    let items: [StashItem]
    let onMerge: (_ targetID: String, _ sourceIDs: [String]) -> Void
    let onCancel: () -> Void

    @State private var targetID: String

    init(items: [StashItem],
         onMerge: @escaping (_ targetID: String, _ sourceIDs: [String]) -> Void,
         onCancel: @escaping () -> Void) {
        self.items = items
        self.onMerge = onMerge
        self.onCancel = onCancel
        // Default the keeper to whichever item has the most
        // attached files already — most likely the one the user
        // has invested edits in. Falls back to the first selected
        // when nothing has attachments.
        let initial = items.max(by: { ($0.files?.count ?? 0) < ($1.files?.count ?? 0) })
        _targetID = State(initialValue: initial?.id ?? items.first?.id ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Merge \(items.count) items")
                .font(.title3.weight(.semibold))
            Text("Choose the keeper. Every other selected item will fold into it: its primary photo becomes an attached file on the keeper, tags union, notes append below `---`, and the source item is deleted.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(items) { item in
                        targetRow(item: item)
                    }
                }
            }
            .frame(maxHeight: 360)

            Divider()
            mergePlan
            HStack {
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Merge") {
                    let sources = items.map(\.id).filter { $0 != targetID }
                    onMerge(targetID, sources)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(items.count < 2 || targetID.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    @ViewBuilder
    private func targetRow(item: StashItem) -> some View {
        let isTarget = item.id == targetID
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isTarget ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(isTarget ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title.isEmpty ? "(untitled)" : item.title)
                    .font(.body.weight(isTarget ? .semibold : .regular))
                HStack(spacing: 8) {
                    Text(item.shortID)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                    if let attached = item.files?.count, attached > 0 {
                        Text("+\(attached) attached")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let tags = item.tags, !tags.isEmpty {
                        Text(tags.prefix(3).map { "#\($0.name)" }.joined(separator: " "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer()
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isTarget ? Color.accentColor.opacity(0.10) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { targetID = item.id }
    }

    /// Concrete "here's what will happen" block — flatten the picker
    /// state into specific counts so the user knows exactly what
    /// they're confirming. Most important detail: total file count
    /// on the keeper after merge.
    private var mergePlan: some View {
        let sources = items.filter { $0.id != targetID }
        let target = items.first(where: { $0.id == targetID })
        let incomingFiles = sources.reduce(0) { acc, src in
            acc + 1 + (src.files?.count ?? 0)
        }
        let totalFiles = (target.flatMap { 1 + ($0.files?.count ?? 0) } ?? 0) + incomingFiles
        return VStack(alignment: .leading, spacing: 2) {
            Text("After merge:")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("• Keeper carousel will hold \(totalFiles) photo(s).")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("• Tags from \(sources.count) item(s) union into keeper.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("• Notes append below `---` separator (where non-empty).")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("• \(sources.count) source item(s) deleted.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
