import SwiftUI

/// "See all" popover anchored on the Collections section header in
/// the sidebar. Only renders Static Collections — Smart Collections
/// stay fully listed in the sidebar so users always have direct
/// access to them. A filter field at the top narrows the visible
/// list on each keystroke; picking a row navigates the sidebar and
/// dismisses the popover via the caller's `onPick` closure.
struct AllCollectionsPopover: View {
    let collections: [StashCollection]
    let onPick: (StashCollection) -> Void

    @State private var filter: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            list
        }
        .frame(width: 280, height: 360)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("All collections")
                .font(.headline)
            FilterField(
                placeholder: "Filter…",
                text: $filter,
                autoFocus: true
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var list: some View {
        let matches = filtered
        if matches.isEmpty {
            VStack {
                Spacer()
                Text(collections.isEmpty
                     ? "No collections yet."
                     : "No collections match \"\(filter)\".")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(matches) { col in
                        Button {
                            onPick(col)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "folder")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 16)
                                Text(col.name)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var filtered: [StashCollection] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let sorted = collections.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        guard !needle.isEmpty else { return sorted }
        return sorted.filter { $0.name.lowercased().contains(needle) }
    }
}
