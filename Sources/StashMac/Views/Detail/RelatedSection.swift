import SwiftUI

/// "Related items" — up to 5 stashed items that overlap with the
/// current one by shared tags, shared collections, manual links,
/// URL domain, or matching content_hash. The Go side does the
/// scoring (`stash related <id> --json`); we just render the result
/// list and let clicks navigate to the picked item.
struct RelatedSection: View {
    @Environment(StashStore.self) private var store
    let itemID: String

    @State private var items: [StashItem] = []
    @State private var loading = true

    var body: some View {
        Group {
            if loading {
                // Stabilized loader: fixed height prevents the
                // section below (Info) from jittering or bouncing
                // as much while the CLI is working.
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading related...")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .frame(height: 60)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if !items.isEmpty {
                DetailSection(title: "Related items") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(items) { item in
                            row(item)
                        }
                    }
                }
            }
        }
        .task(id: itemID) {
            do {
                // Debounce selection: wait 150ms before triggering heavy CLI calls.
                try await Task.sleep(nanoseconds: 150 * 1_000_000)
                
                await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { await reload() }
                    group.addTask {
                        try await Task.sleep(nanoseconds: 10 * 1_000_000_000)
                        throw CancellationError()
                    }
                    _ = try? await group.next()
                    group.cancelAll()
                }
            } catch {
                // Task was cancelled, do nothing
            }
        }
    }

    /// Click target = icon + text content, NOT the trailing whitespace.
    /// User preference; see `feedback_related_items_text_only_clickable.md`
    /// in memory before widening to a full-row hit. The Spacer stays
    /// outside the Button so the dead horizontal space past the row's
    /// content isn't clickable.
    @ViewBuilder
    private func row(_ item: StashItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Button {
                store.selectItemByID(item.id, revealInList: true)
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: item.type.icon)
                        .frame(width: 18)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title)
                            .font(.callout)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            Text(item.type.label.dropLast())
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            if let tags = item.tags, !tags.isEmpty {
                                Text(tags.prefix(3).map { "#\($0.name)" }.joined(separator: " "))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help("Open in list")
            Spacer()
        }
        .padding(.vertical, 3)
    }

    private func reload() async {
        loading = true
        defer { loading = false }
        do {
            items = try await StashCLI.shared.relatedItems(id: itemID, limit: 5)
        } catch {
            // Quiet failure — empty array hides the section.
            items = []
        }
    }
}
