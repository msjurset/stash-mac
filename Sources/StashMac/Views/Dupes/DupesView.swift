import SwiftUI

struct DupesView: View {
    @Environment(StashStore.self) private var store
    @State private var confirmDeleteID: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if store.isDupeRunning {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text("Scanning for duplicates...")
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 40)
                } else if store.dupeResults.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "doc.on.doc")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("Scan for duplicate items")
                            .foregroundStyle(.secondary)
                        Button("Find Duplicates") {
                            store.loadDupes()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 40)
                } else {
                    Text("\(store.dupeResults.count) duplicate group(s)")
                        .font(.headline)

                    ForEach(store.dupeResults) { group in
                        dupeGroupView(group)
                    }
                }
            }
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            if let msg = store.flashMessage {
                Text(msg)
                    .font(.callout)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .shadow(radius: 4)
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .animation(.easeInOut, value: store.flashMessage)
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    store.loadDupes()
                } label: {
                    Label("Scan", systemImage: "arrow.clockwise")
                }
                .help("Scan for duplicates")
                .disabled(store.isDupeRunning)
            }
        }
        .alert("Delete Item", isPresented: .init(
            get: { confirmDeleteID != nil },
            set: { if !$0 { confirmDeleteID = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let id = confirmDeleteID {
                    store.deleteItemFromDupes(id: id)
                }
                confirmDeleteID = nil
            }
            Button("Cancel", role: .cancel) {
                confirmDeleteID = nil
            }
        } message: {
            Text("This item will be permanently deleted.")
        }
    }

    @ViewBuilder
    private func dupeGroupView(_ group: DupeResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // Group header
            HStack {
                Text(group.methodLabel)
                    .font(.subheadline.bold())
                    .foregroundStyle(colorForMethod(group.method))
                Spacer()
                Text(truncateKey(group.key))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button {
                    store.dismissDupeGroup(group)
                } label: {
                    Text("Dismiss")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .help("Dismiss to mark these items as non-duplicate or otherwise accepted as they are")
            }

            // Items in group
            ForEach(group.items) { item in
                dupeItemRow(item)
            }
        }
        .padding(.vertical, 6)

        Divider()
    }

    @ViewBuilder
    private func dupeItemRow(_ item: DupeItem) -> some View {
        let isSelected = store.selectedItemID == item.id
        HStack {
            Text(item.title)
                .lineLimit(1)

            Spacer()

            if let detail = item.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(String(item.id.prefix(10)))
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture {
            store.selectItemByID(item.id)
        }
        .contextMenu {
            Button("Show in All Items") {
                store.selectedItemID = item.id
                store.applyNavigation(.allItems)
            }
            Button("Open") {
                store.openItem(id: item.id)
            }
            Divider()
            Button("Delete Duplicate", role: .destructive) {
                confirmDeleteID = item.id
            }
        }
    }

    private func colorForMethod(_ method: String) -> Color {
        switch method {
        case "hash": return .purple
        case "url": return .red
        case "title": return .orange
        default: return .secondary
        }
    }

    private func truncateKey(_ key: String) -> String {
        if key.count > 40 {
            return String(key.prefix(40)) + "..."
        }
        return key
    }
}
