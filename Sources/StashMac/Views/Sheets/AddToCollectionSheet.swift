import SwiftUI

/// Sheet for `stash collection add-to` — pick destination Static
/// Collection(s) for a source. Source can be any combination of
/// Static + Smart Collections; destinations must be Static. The
/// "Create New Collection…" row at the bottom of the destination
/// list opens an inline name field so a Smart Collection's current
/// results can be snapshotted into a fresh Static Collection in
/// one move.
///
/// Source resolution + upsert happen CLI-side via
/// `stash collection add-to`. This sheet only collects the user's
/// destination picks.
struct AddToCollectionSheet: View {
    /// Source description — surfaced in the header so the user
    /// can confirm what they're about to copy. Doesn't drive
    /// behavior; the source list (below) is the ground truth.
    let sourceLabel: String
    let sources: [String]
    /// Every Static Collection the user could pick as a
    /// destination. The source(s) are filtered out so a
    /// collection can't be its own destination.
    let availableDestinations: [StashCollection]
    let onCommit: (
        _ destinations: [String],
        _ createNew: String?,
        _ description: String?
    ) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var picked: Set<String> = []
    @State private var creatingNew: Bool = false
    @State private var newName: String = ""
    @State private var newDescription: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Items to Collection")
                .font(.headline)
            Text("Adds every item in \(sourceLabel) to the destination(s) below. Items already in a destination are skipped — no duplicates. The source isn't touched.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                Text("Destinations")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filteredDestinations) { col in
                            destinationRow(col)
                        }
                        Divider()
                            .padding(.vertical, 6)
                        createNewRow
                    }
                    .padding(.vertical, 4)
                }
                .frame(height: 200)
                .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 6))
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    let createPayload = creatingNew && !trimmedNewName.isEmpty
                        ? trimmedNewName
                        : nil
                    onCommit(
                        Array(picked),
                        createPayload,
                        createPayload != nil && !newDescription.isEmpty
                            ? newDescription
                            : nil
                    )
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!commitEnabled)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 440)
    }

    /// Click-anywhere row with a leading checkmark badge that
    /// reflects selection state. Manual button + checkmark rather
    /// than a SwiftUI Toggle because the .checkbox toggle style
    /// fought the label HStack on macOS, intermittently hiding the
    /// collection-name text under its own padding.
    @ViewBuilder
    private func destinationRow(_ col: StashCollection) -> some View {
        let isSelected = picked.contains(col.name)
        Button {
            if isSelected { picked.remove(col.name) }
            else          { picked.insert(col.name) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(width: 16)
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(col.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The Create-New affordance is split into a "click to expand"
    /// row + inline name field so the picker stays compact when
    /// the user just wants existing destinations.
    @ViewBuilder
    private var createNewRow: some View {
        if creatingNew {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "folder.badge.plus")
                        .foregroundStyle(.tint)
                    Text("New Collection")
                        .font(.callout.weight(.medium))
                    Spacer()
                    Button {
                        creatingNew = false
                        newName = ""
                        newDescription = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Cancel new collection")
                }
                FilterField(
                    placeholder: "Name",
                    text: $newName,
                    autoFocus: true
                )
                FilterField(
                    placeholder: "Description (optional)",
                    text: $newDescription
                )
            }
            .padding(8)
            .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
        } else {
            Button {
                creatingNew = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder.badge.plus")
                    Text("Create New Collection…")
                    Spacer()
                }
                .foregroundStyle(.tint)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var filteredDestinations: [StashCollection] {
        let srcSet = Set(sources)
        return availableDestinations
            .filter { !srcSet.contains($0.name) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var trimmedNewName: String {
        newName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var commitEnabled: Bool {
        if !picked.isEmpty { return true }
        if creatingNew && !trimmedNewName.isEmpty { return true }
        return false
    }
}
