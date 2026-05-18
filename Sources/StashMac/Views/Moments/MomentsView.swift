import SwiftUI

/// Sidebar Tools entry that surfaces clusters of recently-captured
/// items that look like trips or events — multiple items in a short
/// time window, often sharing a location or a tag. Each suggestion
/// is a one-click "Accept as Collection" path that creates (or
/// reuses) a collection and adds every item in the cluster.
///
/// All the clustering and scoring logic lives in the gostash CLI
/// (`stash moments --json`). This view is a thin renderer over
/// that output plus an accept button that shells out to
/// `stash moments accept`. Refresh re-runs the CLI; --all
/// widens the scan from the default 90-day window to the whole
/// stash for users who want to retroactively bundle older bursts.
struct MomentsView: View {
    @State private var renaming: StashCLI.MomentSuggestion?

    @Environment(StashStore.self) private var store

    // Read-through accessors so the body code reads the same as
    // before. Moments results live on StashStore so revisiting
    // this view (back/forward, sidebar reselection) shows the cached
    // list instantly instead of re-running the CLI on every appear.
    private var suggestions: [StashCLI.MomentSuggestion] { store.moments }
    private var loading: Bool { store.momentsLoading }
    private var error: String? { store.momentsError }
    private var scanAll: Bool { store.momentsScanAll }
    private var scanAllBinding: Binding<Bool> {
        Binding(
            get: { store.momentsScanAll },
            set: { newValue in
                guard newValue != store.momentsScanAll else { return }
                Task { await store.loadMoments(scanAll: newValue, forceReload: true) }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            // Cache-aware: returns immediately if the store already
            // has a list loaded with the current scope. Only the
            // first visit (or a flipped scanAll, or the Refresh
            // button) actually hits the CLI.
            await store.loadMoments(scanAll: scanAll)
        }
        .sheet(item: $renaming) { suggestion in
            // Accept only the items still checked in the detail
            // pane. When the user hasn't opened the detail pane yet,
            // selectedMomentItemIDs is empty for this suggestion and
            // we fall back to "everything" — preserves the original
            // one-click-from-the-middle-pane flow.
            let selected = effectiveSelection(for: suggestion)
            AcceptSheet(
                suggestion: suggestion,
                selectedIDs: selected,
                onAccept: { name, desc in
                    Task { await accept(
                        suggestion: suggestion,
                        ids: selected,
                        name: name,
                        description: desc
                    ) }
                }
            )
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Moments")
                    .font(.title3.weight(.semibold))
                Text(headerSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    // Reserve 2 lines so 1-vs-2-line variations
                    // ("Scanning…" vs "4 clusters found in last 90
                    // days.") don't bounce the divider height.
                    // Matches the right-pane header so the panes'
                    // bottom edges line up against the same divider.
                    .lineLimit(2, reservesSpace: true)
            }
            Spacer()
            Toggle(isOn: scanAllBinding) {
                Text("Scan all history")
                    .font(.caption)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            Button {
                Task { await store.loadMoments(scanAll: scanAll, forceReload: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(loading)
            .help("Refresh")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var headerSubtitle: String {
        let window = scanAll ? "all history" : "last 90 days"
        switch suggestions.count {
        case 0 where loading: return "Scanning \(window)…"
        case 0: return "No trip-shaped clusters in \(window)."
        case 1: return "1 cluster found in \(window)."
        default: return "\(suggestions.count) clusters found in \(window)."
        }
    }

    @ViewBuilder
    private var content: some View {
        if let error {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Retry") {
                    Task { await store.loadMoments(scanAll: scanAll, forceReload: true) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else if suggestions.isEmpty && !loading {
            VStack(spacing: 8) {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 36))
                    .foregroundStyle(.tertiary)
                Text("Nothing to suggest right now.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Stash a burst of items in a short time window and they'll cluster here.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(suggestions) { suggestion in
                        SuggestionCard(
                            suggestion: suggestion,
                            isSelected: store.selectedMoment?.id == suggestion.id,
                            onSelect: { store.selectedMoment = suggestion },
                            onAccept: { renaming = suggestion }
                        )
                    }
                }
                .padding(16)
            }
            .overlay(alignment: .top) {
                if loading {
                    ProgressView()
                        .controlSize(.small)
                        .padding(6)
                        .background(.background.opacity(0.85), in: Capsule())
                        .padding(.top, 6)
                }
            }
        }
    }

    private func accept(
        suggestion: StashCLI.MomentSuggestion,
        ids: [String],
        name: String,
        description: String?
    ) async {
        guard !ids.isEmpty else { return }
        do {
            try await StashCLI.shared.acceptMoment(
                name: name,
                ids: ids,
                description: description
            )
            // Reload top-level state so the new collection appears in
            // the sidebar, then force-refresh suggestions so the
            // now-grouped cluster drops out of the list.
            store.loadAll()
            await store.loadMoments(scanAll: scanAll, forceReload: true)
        } catch {
            store.momentsError = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    /// IDs to send to accept: the user's per-item selection from the
    /// detail pane if it covers any item in the suggestion, else
    /// every item in the suggestion (one-click-without-review path).
    private func effectiveSelection(for suggestion: StashCLI.MomentSuggestion) -> [String] {
        let allIDs = suggestion.items.map(\.id)
        let intersected = allIDs.filter { store.selectedMomentItemIDs.contains($0) }
        return intersected.isEmpty ? allIDs : intersected
    }
}

// MARK: - Suggestion card

private struct SuggestionCard: View {
    let suggestion: StashCLI.MomentSuggestion
    let isSelected: Bool
    let onSelect: () -> Void
    let onAccept: () -> Void

    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        return df
    }()

    private static let dayFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(suggestion.suggestedName)
                    .font(.headline)
                Spacer()
                Text(String(format: "%.0f pts", suggestion.score))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Text("\(suggestion.itemCount) items · \(rangeString)")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let shared = suggestion.sharedTags, !shared.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "tag")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    ForEach(shared, id: \.self) { tag in
                        Text(tag)
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.tint.opacity(0.15), in: Capsule())
                            .foregroundStyle(.tint)
                    }
                }
            }

            if let loc = suggestion.locationCenter, let count = suggestion.locationCount {
                HStack(spacing: 4) {
                    Image(systemName: "location")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(String(format: "%.4f, %.4f", loc.lat, loc.lon))
                        .font(.caption.monospacedDigit())
                    Text("· \(count) geo-tagged")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            HStack {
                Spacer()
                Button("Accept as Collection…") { onAccept() }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            // Tint the selected card so the user can tell at a glance
            // which cluster the right pane is showing. .thickMaterial
            // for unselected keeps a subtle elevation so the cards
            // still read as distinct.
            isSelected
                ? AnyShapeStyle(.tint.opacity(0.12))
                : AnyShapeStyle(.thickMaterial),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.25),
                        lineWidth: isSelected ? 2 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture(perform: onSelect)
    }

    private var rangeString: String {
        let sameDay = Calendar.current.isDate(
            suggestion.start, inSameDayAs: suggestion.end
        )
        if sameDay {
            return Self.dayFormatter.string(from: suggestion.start)
        }
        return "\(Self.dayFormatter.string(from: suggestion.start)) → \(Self.dayFormatter.string(from: suggestion.end))"
    }
}

// MARK: - Filmstrip tile

private struct FilmstripTile: View {
    let item: StashCLI.MomentSuggestion.MomentItem

    var body: some View {
        AsyncThumbnailImage(
            relativePath: item.thumbnailPath,
            fallback: {
                ZStack {
                    Rectangle().fill(.secondary.opacity(0.15))
                    Text(iconFor(type: item.type))
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                }
            }
        )
        .frame(width: 48, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(.quaternary, lineWidth: 1)
        )
        .help(item.title?.isEmpty == false ? item.title! : item.id)
    }

    /// Emoji that mirrors what the help/list views use for the item
    /// type. Keeps the filmstrip readable even when thumbnails are
    /// missing (older items pre-thumbnail-backfill, snippet/email).
    private func iconFor(type: String?) -> String {
        switch type {
        case "image":   return "🖼️"
        case "url":     return "🌐"
        case "file":    return "📁"
        case "snippet": return "📄"
        case "email":   return "✉️"
        default:        return "•"
        }
    }
}

// MARK: - Accept sheet

private struct AcceptSheet: View {
    let suggestion: StashCLI.MomentSuggestion
    let selectedIDs: [String]
    let onAccept: (String, String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var description: String = ""

    init(
        suggestion: StashCLI.MomentSuggestion,
        selectedIDs: [String],
        onAccept: @escaping (String, String?) -> Void
    ) {
        self.suggestion = suggestion
        self.selectedIDs = selectedIDs
        self.onAccept = onAccept
        _name = State(initialValue: suggestion.suggestedName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Accept Moment")
                .font(.headline)
            Text(detailLine)
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("Name").font(.caption).foregroundStyle(.secondary)
                FilterField(
                    placeholder: "Collection name",
                    text: $name,
                    autoFocus: true,
                    onSubmit: commit
                )
                .frame(width: 360)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Description (optional)").font(.caption).foregroundStyle(.secondary)
                FilterField(
                    placeholder: "Anything you want to remember about this trip",
                    text: $description
                )
                .frame(width: 360)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Accept") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        name.trimmingCharacters(in: .whitespaces).isEmpty
                            || selectedIDs.isEmpty
                    )
            }
            .padding(.top, 4)
        }
        .padding(20)
    }

    private func commit() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty, !selectedIDs.isEmpty else { return }
        let trimmedDesc = description.trimmingCharacters(in: .whitespaces)
        onAccept(trimmedName, trimmedDesc.isEmpty ? nil : trimmedDesc)
        dismiss()
    }

    /// "Creates the collection… and adds 12 of 19 items." Surfaces
    /// the user's selection edits so accepting feels intentional.
    private var detailLine: String {
        let total = suggestion.items.count
        let count = selectedIDs.count
        if count == total {
            return "Creates the collection if it doesn't exist and adds \(total) items."
        }
        return "Creates the collection if it doesn't exist and adds \(count) of \(total) items."
    }
}
