import SwiftUI
import AppKit

/// Master-detail feed management and health inspector sheet.
/// Selecting a feed in the left column reveals its full health diagnostics
/// (untruncated poll errors, single-feed "Poll Now" test with live found/new
/// counts, timestamps), candidate breakdown and recent entries, and an
/// in-place configuration editor backed by `stash feeds edit`.
struct ManageFeedsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(StashStore.self) private var store

    @State private var sources: [FeedSource] = []
    @State private var selectedSourceID: Int64?
    @State private var loading = true
    @State private var loadError: String?
    @State private var removalTarget: FeedSource?

    // Single-source or all-source poll state
    @State private var pollingSourceID: Int64?
    @State private var pollingAll = false
    @State private var lastPollSummary: FeedRefreshSourceSummary?
    @State private var lastPollTimestamp: Date?
    @State private var pollActionError: String?

    // Per-source candidate stats & recent items
    @State private var candidates: [FeedCandidate] = []
    @State private var loadingCandidates = false
    @State private var candidateFilter: String = "all"

    // Editable form state for the selected source
    @State private var editName = ""
    @State private var editURL = ""
    @State private var editKind = "rss"
    @State private var editTags = ""
    @State private var editCollection = ""
    @State private var editInterval = 360
    @State private var editEnabled = true
    @State private var editAutoStash = false
    @State private var editFetchContent = false
    @State private var savingEdits = false
    @State private var editError: String?
    @State private var editSavedBanner = false

    private var selectedSource: FeedSource? {
        guard let id = selectedSourceID else { return nil }
        return sources.first(where: { $0.id == id })
    }

    private var errorCount: Int {
        sources.filter(\.hasError).count
    }

    private var healthyCount: Int {
        sources.filter(\.isHealthy).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            Divider()

            if loading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadError {
                ContentUnavailableView(
                    "Couldn't load feeds",
                    systemImage: "exclamationmark.triangle",
                    description: Text(loadError)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if sources.isEmpty {
                ContentUnavailableView(
                    "No feeds yet",
                    systemImage: "antenna.radiowaves.left.and.right",
                    description: Text("Add a feed from the Inbox header.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    masterList
                        .frame(width: 310)
                    Divider()
                    detailPane
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(width: 900, height: 600)
        .onAppear { Task { await reload(preserveSelection: false) } }
        .onChange(of: selectedSourceID) { _, newID in
            lastPollSummary = nil
            lastPollTimestamp = nil
            pollActionError = nil
            editError = nil
            editSavedBanner = false
            candidateFilter = "all"
            if let src = sources.first(where: { $0.id == newID }) {
                populateEditor(from: src)
                Task { await loadCandidates(for: src.id) }
            } else {
                candidates = []
            }
        }
        .confirmationDialog(
            "Remove feed?",
            isPresented: Binding(get: { removalTarget != nil }, set: { if !$0 { removalTarget = nil } }),
            presenting: removalTarget
        ) { target in
            Button("Remove “\(target.name)”", role: .destructive) {
                Task { await remove(target) }
            }
            Button("Cancel", role: .cancel) { removalTarget = nil }
        } message: { target in
            Text("This deletes the subscription and any unread candidates. Already-stashed items are kept.")
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 10) {
            Text("Feed Sources").font(.title3).bold()

            if !sources.isEmpty {
                HStack(spacing: 6) {
                    Text("\(sources.count) total")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if healthyCount > 0 {
                        statusPill(
                            text: "\(healthyCount) healthy",
                            icon: "checkmark.circle.fill",
                            color: .green
                        )
                    }
                    if errorCount > 0 {
                        statusPill(
                            text: "\(errorCount) \(errorCount == 1 ? "error" : "errors")",
                            icon: "exclamationmark.triangle.fill",
                            color: .red
                        )
                    }
                }
            }

            Spacer()

            Button {
                Task { await pollAllSources() }
            } label: {
                HStack(spacing: 4) {
                    if pollingAll {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                    }
                    Text("Poll All")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .focusable(false)
            .disabled(pollingAll || pollingSourceID != nil || sources.isEmpty)
            .help("Poll all enabled feed sources now")

            Button {
                Task { await reload(preserveSelection: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .focusable(false)
            .help("Refresh list")

            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    // MARK: - Master List

    private var masterList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(sources) { src in
                    row(src)
                    Divider()
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ src: FeedSource) -> some View {
        let isSelected = src.id == selectedSourceID
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(healthColor(for: src))
                .frame(width: 8, height: 8)
                .padding(.top, 5)
                .help(healthTooltip(for: src))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(src.name)
                        .font(.headline)
                        .lineLimit(1)
                    if src.autoStash == true {
                        badgePill("auto", color: .accentColor)
                    }
                    if src.fetchContent == true {
                        badgePill("full-text", color: .blue)
                    }
                    if !src.enabled {
                        badgePill("disabled", color: .secondary)
                    }
                }
                Text(src.url)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .truncationMode(.middle)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if let polled = src.lastPolledAt {
                        Text("polled \(polled.formatted(.relative(presentation: .numeric)))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    } else {
                        Text("never polled")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    if let err = src.lastError, !err.isEmpty {
                        Text("· \(err)")
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 4)
            Button {
                removalTarget = src
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red.opacity(0.85))
            }
            .buttonStyle(.borderless)
            .focusable(false)
            .help("Remove this feed")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            selectedSourceID = src.id
        }
    }

    // MARK: - Detail Inspector

    @ViewBuilder
    private var detailPane: some View {
        if let src = selectedSource {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    healthSection(for: src)
                    Divider()
                    candidatesSection(for: src)
                    Divider()
                    configurationSection(for: src)
                }
                .padding(20)
            }
        } else {
            ContentUnavailableView(
                "Select a Feed",
                systemImage: "antenna.radiowaves.left.and.right",
                description: Text("Click a feed on the left to inspect its health, recent candidates, and settings.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Health & Live Poll Section

    @ViewBuilder
    private func healthSection(for src: FeedSource) -> some View {
        let isPollingThis = pollingSourceID == src.id
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(src.name)
                            .font(.title3).bold()
                        healthBadge(for: src)
                    }
                    Text("Feed #\(src.id) · \(src.kind.uppercased()) · polls every \(src.pollIntervalMinutes) min")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let feedURL = URL(string: src.url) {
                    Button {
                        NSWorkspace.shared.open(feedURL)
                    } label: {
                        Label("Open Feed URL", systemImage: "safari")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .focusable(false)
                    .help("Open raw feed URL in browser")
                }

                Button {
                    Task { await pollSingleSource(src) }
                } label: {
                    HStack(spacing: 5) {
                        if isPollingThis {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                        Text(isPollingThis ? "Polling…" : "Poll Now")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .focusable(false)
                .disabled(isPollingThis || pollingAll)
                .help("Fetch this feed now and report found/new entries or errors")
            }

            // Timestamps grid
            HStack(spacing: 24) {
                metadataItem(
                    label: "Last Polled",
                    value: src.lastPolledAt.map {
                        "\($0.formatted(.relative(presentation: .numeric))) (\($0.formatted(date: .abbreviated, time: .shortened)))"
                    } ?? "Never"
                )
                metadataItem(
                    label: "Subscribed",
                    value: src.createdAt.formatted(date: .abbreviated, time: .omitted)
                )
                metadataItem(
                    label: "Updated",
                    value: src.updatedAt.formatted(date: .abbreviated, time: .shortened)
                )
            }

            // Full error diagnostic card when the feed has a poll error
            if let err = src.lastError, !err.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "exclamationmark.octagon.fill")
                            .foregroundStyle(.red)
                        Text("Last Poll Error")
                            .font(.subheadline).bold()
                            .foregroundStyle(.red)
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(err, forType: .string)
                        } label: {
                            Label("Copy Error", systemImage: "doc.on.doc")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .focusable(false)
                    }
                    Text(err)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(diagnosticHint(for: err))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .background(Color.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.red.opacity(0.30), lineWidth: 1)
                )
            }

            // Live Poll Result feedback banner
            if let summary = lastPollSummary {
                let failed = !(summary.error ?? "").isEmpty
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: failed ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(failed ? .red : .green)
                    VStack(alignment: .leading, spacing: 2) {
                        if let pollErr = summary.error, !pollErr.isEmpty {
                            Text("Test poll failed: \(pollErr)")
                                .font(.caption).bold()
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                        } else {
                            Text(livePollSummaryLine(summary))
                                .font(.caption).bold()
                        }
                        if let ts = lastPollTimestamp {
                            Text("Checked at \(ts.formatted(date: .omitted, time: .standard))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                .padding(10)
                .background((failed ? Color.red : Color.green).opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            }

            if let pollActionError {
                Text(pollActionError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - Candidates Stats & Recent Entries Section

    @ViewBuilder
    private func candidatesSection(for src: FeedSource) -> some View {
        let stats = FeedCandidateStats(candidates: candidates)
        let filtered = filteredCandidates
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Candidate Activity")
                    .font(.subheadline).bold()
                Spacer()
                if loadingCandidates {
                    ProgressView().controlSize(.small)
                }
            }

            HStack(spacing: 8) {
                statFilterButton(key: "all", label: "Total", count: stats.total, color: .primary)
                statFilterButton(key: "unread", label: "Unread", count: stats.unread, color: .blue)
                statFilterButton(key: "stashed", label: "Stashed", count: stats.stashed, color: .green)
                statFilterButton(key: "snoozed", label: "Snoozed", count: stats.snoozed, color: .orange)
                statFilterButton(key: "dismissed", label: "Dismissed", count: stats.dismissed, color: .secondary)
            }

            if !loadingCandidates && candidates.isEmpty {
                Text("No candidates ingested from this feed yet. Click “Poll Now” above to test fetching entries.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else if !filtered.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(filtered.prefix(8)) { cand in
                        HStack(spacing: 8) {
                            candidateStateBadge(cand.state)
                            Text(cand.displayTitle)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer()
                            Text(cand.displayWhen.formatted(.relative(presentation: .numeric)))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            if let u = URL(string: cand.url) {
                                Button {
                                    NSWorkspace.shared.open(u)
                                } label: {
                                    Image(systemName: "arrow.up.right.square")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                                .focusable(false)
                                .help("Open candidate URL in browser")
                            }
                        }
                        .padding(.vertical, 5)
                        .padding(.horizontal, 8)
                        if cand.id != filtered.prefix(8).last?.id {
                            Divider()
                        }
                    }
                }
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1)
                )
            } else if !loadingCandidates {
                Text("No \(candidateFilter) candidates for this feed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }
        }
    }

    private var filteredCandidates: [FeedCandidate] {
        guard candidateFilter != "all" else { return candidates }
        return candidates.filter { $0.state == candidateFilter }
    }

    // MARK: - Configuration & In-Place Edit Section

    @ViewBuilder
    private func configurationSection(for src: FeedSource) -> some View {
        let dirty = hasUnsavedChanges(comparedTo: src)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Feed Settings")
                    .font(.subheadline).bold()
                Spacer()
                if editSavedBanner {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }

            Form {
                LabeledContent("Name") {
                    FilterField(
                        placeholder: "Display name",
                        text: $editName,
                        isBordered: true,
                        backgroundColor: .textBackgroundColor
                    )
                    .frame(height: 22)
                }
                LabeledContent("Feed URL") {
                    FilterField(
                        placeholder: "https://example.com/rss.xml",
                        text: $editURL,
                        isBordered: true,
                        backgroundColor: .textBackgroundColor
                    )
                    .frame(height: 22)
                }
                LabeledContent("Kind") {
                    Picker("", selection: $editKind) {
                        Text("RSS / Atom").tag("rss")
                        Text("YouTube channel").tag("youtube")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                LabeledContent("Default tags") {
                    FilterField(
                        placeholder: "comma-separated",
                        text: $editTags,
                        isBordered: true,
                        backgroundColor: .textBackgroundColor
                    )
                    .frame(height: 22)
                }
                LabeledContent("Default collection") {
                    Picker("", selection: $editCollection) {
                        Text("None").tag("")
                        ForEach(store.collections, id: \.name) { c in
                            Text(c.name).tag(c.name)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                LabeledContent("Poll every") {
                    HStack {
                        FilterField(
                            placeholder: "360",
                            text: Binding(
                                get: { String(editInterval) },
                                set: { editInterval = Int($0) ?? 360 }
                            ),
                            isBordered: true,
                            backgroundColor: .textBackgroundColor
                        )
                        .frame(width: 80, height: 22)
                        Text("minutes").foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Polling") {
                    Toggle("Enabled (include in scheduled refreshes)", isOn: $editEnabled)
                        .toggleStyle(.checkbox)
                }
                LabeledContent("Auto-stash") {
                    Toggle("Skip triage; stash new candidates automatically", isOn: $editAutoStash)
                        .toggleStyle(.checkbox)
                }
                LabeledContent("Full-text") {
                    Toggle("Fetch full article body for each new candidate", isOn: $editFetchContent)
                        .toggleStyle(.checkbox)
                }
            }

            if let editError {
                Text(editError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            HStack(spacing: 8) {
                Button("Revert") {
                    populateEditor(from: src)
                    editError = nil
                }
                .disabled(!dirty || savingEdits)
                .focusable(false)

                Spacer()

                Button(savingEdits ? "Saving…" : "Save Changes") {
                    Task { await saveChanges(for: src, pollAfter: false) }
                }
                .disabled(!dirty || !canSaveEdits || savingEdits)
                .focusable(false)

                Button("Save & Poll Now") {
                    Task { await saveChanges(for: src, pollAfter: true) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!dirty || !canSaveEdits || savingEdits)
                .focusable(false)
                .help("Save edits and immediately test-poll this feed")
            }
        }
    }

    // MARK: - Helpers & Subviews

    private func populateEditor(from src: FeedSource) {
        editName = src.name
        editURL = src.url
        editKind = src.kind.isEmpty ? "rss" : src.kind
        editTags = (src.defaultTags ?? []).joined(separator: ", ")
        editCollection = src.defaultCollection ?? ""
        editInterval = src.pollIntervalMinutes
        editEnabled = src.enabled
        editAutoStash = src.autoStash ?? false
        editFetchContent = src.fetchContent ?? false
    }

    private var parsedEditTags: [String] {
        editTags
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var canSaveEdits: Bool {
        !editName.trimmingCharacters(in: .whitespaces).isEmpty &&
        !editURL.trimmingCharacters(in: .whitespaces).isEmpty &&
        editInterval > 0
    }

    private func hasUnsavedChanges(comparedTo src: FeedSource) -> Bool {
        let trimmedName = editName.trimmingCharacters(in: .whitespaces)
        let trimmedURL = editURL.trimmingCharacters(in: .whitespaces)
        let origTags = src.defaultTags ?? []
        let origCollection = src.defaultCollection ?? ""
        let origAutoStash = src.autoStash ?? false
        let origFetchContent = src.fetchContent ?? false

        return trimmedName != src.name ||
            trimmedURL != src.url ||
            editKind != src.kind ||
            parsedEditTags != origTags ||
            editCollection != origCollection ||
            editInterval != src.pollIntervalMinutes ||
            editEnabled != src.enabled ||
            editAutoStash != origAutoStash ||
            editFetchContent != origFetchContent
    }

    private func healthColor(for src: FeedSource) -> Color {
        if !src.enabled { return .secondary }
        if src.hasError { return .red }
        if src.lastPolledAt != nil { return .green }
        return .orange
    }

    private func healthTooltip(for src: FeedSource) -> String {
        if !src.enabled { return "Polling disabled" }
        if let err = src.lastError, !err.isEmpty { return "Poll error: \(err)" }
        if src.lastPolledAt != nil { return "Healthy" }
        return "Never polled"
    }

    @ViewBuilder
    private func healthBadge(for src: FeedSource) -> some View {
        if !src.enabled {
            statusPill(text: "Disabled", icon: "pause.circle.fill", color: .secondary)
        } else if src.hasError {
            statusPill(text: "Poll Error", icon: "exclamationmark.triangle.fill", color: .red)
        } else if src.lastPolledAt != nil {
            statusPill(text: "Healthy", icon: "checkmark.circle.fill", color: .green)
        } else {
            statusPill(text: "Not Polled Yet", icon: "clock.fill", color: .orange)
        }
    }

    @ViewBuilder
    private func statusPill(text: String, icon: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(text)
        }
        .font(.caption2).bold()
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(color.opacity(0.16), in: Capsule())
        .foregroundStyle(color)
    }

    @ViewBuilder
    private func badgePill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    @ViewBuilder
    private func metadataItem(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func statFilterButton(key: String, label: String, count: Int, color: Color) -> some View {
        let active = candidateFilter == key
        Button {
            candidateFilter = key
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(count)")
                    .font(.subheadline).bold()
                    .foregroundStyle(color)
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                active ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(active ? Color.accentColor : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .focusable(false)
    }

    @ViewBuilder
    private func candidateStateBadge(_ state: String) -> some View {
        let color: Color = {
            switch state {
            case "unread": return .blue
            case "stashed": return .green
            case "snoozed": return .orange
            default: return .secondary
            }
        }()
        Text(state)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
    }

    private func livePollSummaryLine(_ summary: FeedRefreshSourceSummary) -> String {
        var parts = ["Polled successfully: \(summary.found) found, \(summary.new) new"]
        if let enriched = summary.enriched, enriched > 0 {
            parts.append("\(enriched) full-text enriched")
        }
        if let autoStashed = summary.autoStashed, autoStashed > 0 {
            parts.append("\(autoStashed) auto-stashed")
        }
        return parts.joined(separator: " · ")
    }

    private func diagnosticHint(for error: String) -> String {
        let lower = error.lowercased()
        if lower.contains("unknown feed root: \"html\"") || lower.contains("html") {
            return "Hint: The server returned an HTML web page instead of an RSS/Atom XML feed. Click “Open Feed URL” to inspect the page in your browser, or update the Feed URL below."
        }
        if lower.contains("404") || lower.contains("not found") {
            return "Hint: The feed URL returned HTTP 404 Not Found. Check if the site moved its RSS feed address."
        }
        if lower.contains("403") || lower.contains("429") {
            return "Hint: The server rejected or rate-limited the request."
        }
        return "Hint: Click “Open Feed URL” to check the endpoint in your browser, or click “Poll Now” to retry."
    }

    // MARK: - Data Operations

    private func reload(preserveSelection: Bool) async {
        loading = sources.isEmpty
        loadError = nil
        do {
            let loaded = try await StashCLI.shared.listFeedSources()
            sources = loaded
            if preserveSelection, let current = selectedSourceID, loaded.contains(where: { $0.id == current }) {
                if let updated = loaded.first(where: { $0.id == current }) {
                    populateEditor(from: updated)
                }
            } else {
                // Prefer selecting the first errored feed so health issues are immediately visible,
                // otherwise select the first feed.
                let initial = loaded.first(where: \.hasError) ?? loaded.first
                selectedSourceID = initial?.id
                if let initial {
                    populateEditor(from: initial)
                    await loadCandidates(for: initial.id)
                }
            }
        } catch {
            loadError = error.localizedDescription
        }
        loading = false
    }

    private func loadCandidates(for sourceID: Int64) async {
        loadingCandidates = true
        defer { loadingCandidates = false }
        do {
            candidates = try await StashCLI.shared.listFeedCandidates(
                state: "unread,stashed,dismissed,snoozed",
                sourceID: sourceID,
                limit: 200
            )
        } catch {
            candidates = []
        }
    }

    private func pollSingleSource(_ src: FeedSource) async {
        pollingSourceID = src.id
        pollActionError = nil
        defer { pollingSourceID = nil }
        do {
            let response = try await StashCLI.shared.refreshFeeds(sourceID: src.id)
            lastPollSummary = response.sources.first
            lastPollTimestamp = Date()
            let loaded = try await StashCLI.shared.listFeedSources()
            sources = loaded
            await loadCandidates(for: src.id)
            store.loadInbox()
        } catch {
            pollActionError = error.localizedDescription
        }
    }

    private func pollAllSources() async {
        pollingAll = true
        pollActionError = nil
        defer { pollingAll = false }
        do {
            let response = try await StashCLI.shared.refreshFeeds()
            if let current = selectedSource {
                lastPollSummary = response.sources.first(where: { $0.source == current.name })
                lastPollTimestamp = Date()
            }
            let loaded = try await StashCLI.shared.listFeedSources()
            sources = loaded
            if let id = selectedSourceID {
                await loadCandidates(for: id)
            }
            store.loadInbox()
        } catch {
            pollActionError = error.localizedDescription
        }
    }

    private func saveChanges(for src: FeedSource, pollAfter: Bool) async {
        savingEdits = true
        editError = nil
        editSavedBanner = false
        defer { savingEdits = false }
        do {
            let updated = try await StashCLI.shared.editFeedSource(
                id: src.id,
                name: editName.trimmingCharacters(in: .whitespaces),
                url: editURL.trimmingCharacters(in: .whitespaces),
                kind: editKind,
                defaultTags: parsedEditTags,
                defaultCollection: editCollection,
                autoStash: editAutoStash,
                fetchContent: editFetchContent,
                intervalMinutes: editInterval,
                enabled: editEnabled
            )
            if let idx = sources.firstIndex(where: { $0.id == src.id }) {
                sources[idx] = updated
            }
            populateEditor(from: updated)
            editSavedBanner = true
            if pollAfter {
                await pollSingleSource(updated)
            }
        } catch {
            editError = error.localizedDescription
        }
    }

    private func remove(_ src: FeedSource) async {
        do {
            try await StashCLI.shared.removeFeedSource(id: src.id)
            removalTarget = nil
            await reload(preserveSelection: false)
            store.loadInbox()
        } catch {
            loadError = error.localizedDescription
        }
    }
}
