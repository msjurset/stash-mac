import SwiftUI

/// Multi-select tag picker shown as a popover from the main list's
/// right-click "Tags…" action. Behaviors per the user's spec:
///
///   - Auto-applies changes on click-off (popover dismissal). No
///     explicit Apply / Save button.
///   - Currently-applied tags start checked; click toggles. The
///     "applied" baseline is the *intersection* across the target
///     items so a multi-row pick only shows tags that *all* selected
///     rows currently have. Toggling on adds to every item; toggling
///     off removes from every item.
///   - "Add a new tag" is the top input. Type a name, press Enter,
///     and the tag joins the selected set. The popover stays open so
///     you can keep adding / toggling. New tags become real once the
///     popover dismisses and the bulk-tag write applies them.
///   - Filter field below the new-tag input narrows the existing-tag
///     list. The new-tag input handles its own input independently
///     so a partial existing-tag name doesn't leak into "create".
struct TagPickerPopover: View {
    let itemIDs: [String]
    let initialTags: Set<String>
    @Environment(StashStore.self) private var store

    @State private var selected: Set<String>
    @State private var pendingNewTags: [String] = []
    @State private var newTagText: String = ""
    @State private var filterText: String = ""

    init(itemIDs: [String], initialTags: Set<String>) {
        self.itemIDs = itemIDs
        self.initialTags = initialTags
        _selected = State(initialValue: initialTags)
    }

    /// Existing tags from the store plus any pending new ones the
    /// user typed in this session. Filtered case-insensitively by
    /// `filterText`. Sorted by name to stabilize the visual layout
    /// across re-renders.
    private var visibleTagNames: [String] {
        var names = Set(store.tags.map { $0.name })
        names.formUnion(pendingNewTags)
        let sorted = names.sorted()
        if filterText.isEmpty { return sorted }
        let needle = filterText.lowercased()
        return sorted.filter { $0.lowercased().contains(needle) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            addTagField

            Divider()

            filterField

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(visibleTagNames, id: \.self) { name in
                        tagRow(name)
                    }
                    if visibleTagNames.isEmpty {
                        Text(filterText.isEmpty ? "No tags yet" : "No matches")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 8)
                    }
                }
            }
            .frame(maxHeight: 280)
        }
        .padding(12)
        .frame(width: 280)
        .onDisappear { apply() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Tags")
                .font(.subheadline.bold())
            Spacer()
            Text("\(itemIDs.count) item\(itemIDs.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var addTagField: some View {
        HStack(spacing: 4) {
            Image(systemName: "plus.circle")
                .foregroundStyle(.secondary)
            FilterField(
                placeholder: "Add a new tag…",
                text: $newTagText,
                onSubmit: commitNewTag
            )
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 5))
    }

    private var filterField: some View {
        HStack(spacing: 4) {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.caption)
                .foregroundStyle(.tertiary)
            // autoFocus on the filter field, not the add-new-tag field
            // above. The 90% case for opening Tags is "filter to find
            // the tag I want to toggle" — starting focus on the add
            // field meant users had to click into the filter every
            // time before typing.
            FilterField(
                placeholder: "Filter…",
                text: $filterText,
                font: .preferredFont(forTextStyle: .caption1),
                autoFocus: true
            )
            // Clear button inset INSIDE the field's right edge — same
            // pattern as the macOS native search field. Overlay with
            // trailing alignment so the button paints on top of the
            // field, and reserve a bit of trailing padding on the
            // text so typed values don't run under the X.
            .overlay(alignment: .trailing) {
                if !filterText.isEmpty {
                    Button {
                        filterText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear filter")
                    .padding(.trailing, 2)
                    // The FilterField's NSTextField sets an I-beam over
                    // its tracking area, which bleeds through to the X
                    // overlay since the button sits on top of the field.
                    // Push an arrow cursor while hovering so the user
                    // gets the standard "this is clickable" feedback.
                    .onHover { hovering in
                        if hovering {
                            NSCursor.arrow.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 4))
    }

    private func tagRow(_ name: String) -> some View {
        let isSelected = selected.contains(name)
        let count = store.tags.first(where: { $0.name == name })?.count
        return Button {
            toggle(name)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                // No `#` prefix — every row in the list is a tag,
                // so the sigil is redundant noise. Keep it elsewhere
                // (item-row chips, rule descriptions) where tags
                // appear out of context.
                Text(name)
                    .font(.callout)
                Spacer()
                if let count {
                    Text("\(count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func toggle(_ name: String) {
        if selected.contains(name) {
            selected.remove(name)
        } else {
            selected.insert(name)
        }
    }

    private func commitNewTag() {
        let trimmed = newTagText
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "#", with: "")
        guard !trimmed.isEmpty else { return }
        if !pendingNewTags.contains(trimmed) {
            pendingNewTags.append(trimmed)
        }
        selected.insert(trimmed)
        newTagText = ""
    }

    /// Diff against the original applied set and fire one bulk-tag
    /// CLI call covering every add and remove. No-op if nothing
    /// changed (silent dismiss).
    private func apply() {
        let toAdd = Array(selected.subtracting(initialTags))
        let toRemove = Array(initialTags.subtracting(selected))
        guard !toAdd.isEmpty || !toRemove.isEmpty else { return }
        store.bulkApplyTagChanges(
            ids: itemIDs,
            addTags: toAdd,
            removeTags: toRemove
        )
    }
}
