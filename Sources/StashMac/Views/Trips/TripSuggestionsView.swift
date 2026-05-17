import SwiftUI

/// Sidebar Tools entry that surfaces clusters of recently-captured
/// items that look like trips or events — multiple items in a short
/// time window, often sharing a location or a tag. Each suggestion
/// is a one-click "Accept as Collection" path that creates (or
/// reuses) a collection and adds every item in the cluster.
///
/// All the clustering and scoring logic lives in the gostash CLI
/// (`stash trip-suggest --json`). This view is a thin renderer over
/// that output plus an accept button that shells out to
/// `stash trip-suggest accept`. Refresh re-runs the CLI; --all
/// widens the scan from the default 90-day window to the whole
/// stash for users who want to retroactively bundle older bursts.
struct TripSuggestionsView: View {
    @State private var suggestions: [StashCLI.TripSuggestion] = []
    @State private var loading = false
    @State private var error: String?
    @State private var scanAll = false
    @State private var renaming: StashCLI.TripSuggestion?

    @Environment(StashStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await reload() }
        .sheet(item: $renaming) { suggestion in
            AcceptSheet(
                suggestion: suggestion,
                onAccept: { name, desc in
                    Task { await accept(suggestion: suggestion, name: name, description: desc) }
                }
            )
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Trip suggestions")
                    .font(.title3.weight(.semibold))
                Text(headerSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(isOn: $scanAll) {
                Text("Scan all history")
                    .font(.caption)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .onChange(of: scanAll) { _, _ in
                Task { await reload() }
            }
            Button {
                Task { await reload() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(loading)
            .help("Refresh")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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
                Button("Retry") { Task { await reload() } }
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

    private func reload() async {
        loading = true
        defer { loading = false }
        error = nil
        do {
            suggestions = try await StashCLI.shared.tripSuggestions(scanAll: scanAll)
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            suggestions = []
        }
    }

    private func accept(
        suggestion: StashCLI.TripSuggestion,
        name: String,
        description: String?
    ) async {
        do {
            try await StashCLI.shared.tripSuggestAccept(
                name: name,
                ids: suggestion.itemIds,
                description: description
            )
            // Reload top-level state so the new collection appears in
            // the sidebar, then refresh suggestions so the
            // now-grouped cluster drops out of the list.
            store.loadAll()
            await reload()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }
}

// MARK: - Suggestion card

private struct SuggestionCard: View {
    let suggestion: StashCLI.TripSuggestion
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
        .padding(12)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.quaternary, lineWidth: 1)
        )
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

// MARK: - Accept sheet

private struct AcceptSheet: View {
    let suggestion: StashCLI.TripSuggestion
    let onAccept: (String, String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var description: String = ""

    init(
        suggestion: StashCLI.TripSuggestion,
        onAccept: @escaping (String, String?) -> Void
    ) {
        self.suggestion = suggestion
        self.onAccept = onAccept
        _name = State(initialValue: suggestion.suggestedName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Accept Trip Suggestion")
                .font(.headline)
            Text("Creates the collection if it doesn't exist and adds \(suggestion.itemCount) items.")
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
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.top, 4)
        }
        .padding(20)
    }

    private func commit() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }
        let trimmedDesc = description.trimmingCharacters(in: .whitespaces)
        onAccept(trimmedName, trimmedDesc.isEmpty ? nil : trimmedDesc)
        dismiss()
    }
}
