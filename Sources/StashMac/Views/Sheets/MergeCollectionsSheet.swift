import SwiftUI

/// Sheet for `stash collection merge --into …` — fold one or more
/// Static Collections into a surviving one. Smart Collections
/// aren't merge-eligible (they're saved searches, not stored
/// memberships); only Static names show up in the picker.
///
/// Invoked from the sidebar's right-click → "Merge with…" entry on
/// a Static Collection row. The right-clicked collection becomes
/// the seed of the merge set; the user picks the survivor (and any
/// additional merge sources) in this sheet.
struct MergeCollectionsSheet: View {
    /// Names available to merge. Always Static — filtered upstream.
    let candidates: [StashCollection]
    /// Initial selection — the row the user right-clicked. Pre-checks
    /// it so the common "merge this one into another" flow is two
    /// clicks (pick survivor in the dropdown, hit Merge).
    let seedName: String
    let onCommit: (_ survivor: String, _ others: [String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String>
    @State private var survivor: String

    init(
        candidates: [StashCollection],
        seedName: String,
        onCommit: @escaping (String, [String]) -> Void
    ) {
        self.candidates = candidates
        self.seedName = seedName
        self.onCommit = onCommit
        _selected = State(initialValue: [seedName])
        // Default survivor: the first OTHER candidate that isn't
        // the seed. Falls back to the seed when nothing else is
        // available (which means there's nothing to merge — the
        // confirm button stays disabled in that case).
        let defaultSurvivor = candidates
            .map(\.name)
            .first(where: { $0 != seedName }) ?? seedName
        _survivor = State(initialValue: defaultSurvivor)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Merge Collections")
                .font(.headline)
            Text("Pick the surviving collection, then check every collection you want folded into it. Items already in the survivor keep their positions; merged items append at the end. Duplicate memberships collapse silently.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                Text("Survives").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $survivor) {
                    ForEach(candidates) { col in
                        Text(col.name).tag(col.name)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
                .onChange(of: survivor) { _, newSurvivor in
                    // If the new survivor was checked as a source,
                    // drop it from the merge set — a collection
                    // can't fold into itself.
                    selected.remove(newSurvivor)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Folded into the survivor")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(candidates) { col in
                            if col.name != survivor {
                                Toggle(isOn: binding(for: col.name)) {
                                    HStack(spacing: 8) {
                                        Image(systemName: "folder")
                                            .foregroundStyle(.secondary)
                                            .frame(width: 16)
                                        Text(col.name)
                                            .lineLimit(1)
                                    }
                                }
                                .toggleStyle(.checkbox)
                                .padding(.vertical, 3)
                            }
                        }
                    }
                }
                .frame(height: 180)
                .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 6))
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Merge") {
                    onCommit(survivor, others)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(others.isEmpty)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 420)
    }

    private var others: [String] {
        candidates.map(\.name).filter { selected.contains($0) && $0 != survivor }
    }

    private func binding(for name: String) -> Binding<Bool> {
        Binding(
            get: { selected.contains(name) },
            set: { isOn in
                if isOn {
                    selected.insert(name)
                } else {
                    selected.remove(name)
                }
            }
        )
    }
}
