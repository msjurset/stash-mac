import SwiftUI

/// Sheet presented from the Rules toolbar's "Suggest" button. Loads
/// recent manual tag activity, asks the on-device language model to
/// characterize patterns, and shows one card per suggestion.
///
/// Suggestions are accepted as `enabled: false` rules so a generated
/// rule doesn't retroactively re-tag the archive without the user
/// confirming intent in `RuleDetailView` first.
struct SuggestRulesSheet: View {
    @Environment(StashStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    enum Phase {
        case loading
        case ready([RuleSuggestion])
        case error(String)
    }

    @State private var phase: Phase = .loading
    @State private var skipped: Set<String> = []
    /// Snapshot of `SkippedSuggestionsStore` taken at sheet load time.
    /// Drives the footer count + reset button. Refreshed by reading
    /// the store after every analysis run, accept, or reset.
    @State private var dismissedFingerprintCount: Int = 0
    /// True while a fresh analysis is in flight from a refresh / reset.
    /// We keep `phase = .loading` only for the initial open; for
    /// subsequent runs we'd rather keep the previous result visible
    /// behind a small spinner so the UI doesn't jump.
    @State private var refreshing: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(minWidth: 560, minHeight: 360)
            if dismissedFingerprintCount > 0 {
                Divider()
                skippedFooter
            }
        }
        .frame(maxWidth: 720, maxHeight: 600)
        .task { await runAnalysis(initial: true) }
    }

    /// Footer surfacing how many patterns the user has previously
    /// dismissed and a reset button to bring them back. Hidden when
    /// the persisted set is empty so first-time users don't see a
    /// stub. The store covers both Skip *and* Save (saved suggestions
    /// also fingerprint-mark themselves so they don't reappear) — a
    /// reset will resurface saved-but-disabled rules' patterns too,
    /// which is intentional: if you saved without enabling and forgot
    /// about it, seeing it again is the right reminder.
    private var skippedFooter: some View {
        HStack(spacing: 8) {
            Image(systemName: "tray")
                .foregroundStyle(.secondary)
                .font(.caption)
            Text("\(dismissedFingerprintCount) previously dismissed pattern\(dismissedFingerprintCount == 1 ? "" : "s") hidden")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Reset") {
                SkippedSuggestionsStore.shared.clear()
                Task { await runAnalysis(initial: false) }
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Clear the dismissed-patterns memory so they can be suggested again")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.title3)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Suggest Rules")
                        .font(.headline)
                    Text("Computed entirely on-device using Apple Intelligence.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                refreshButton
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            flowHint
        }
        .padding(14)
    }

    /// Re-runs the analysis without dismissing the sheet. Useful after
    /// skipping a few cards (the next pass surfaces the next-best
    /// patterns) or after tagging a few new items in another window.
    private var refreshButton: some View {
        Button {
            Task { await runAnalysis(initial: false) }
        } label: {
            if refreshing {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "arrow.clockwise")
            }
        }
        .buttonStyle(.borderless)
        .disabled(refreshing || isLoading)
        .help("Re-run analysis with the current tag activity")
    }

    private var isLoading: Bool {
        if case .loading = phase { return true }
        return false
    }

    /// Flow explainer covering the new-rule lifecycle that starts
    /// from this sheet. Add Rule hands the proposal to the editor
    /// (where Create writes it disabled); the user then Enables and
    /// optionally Applies retroactively from the rule's detail view.
    private var flowHint: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
                .font(.caption)
            Text("**Add Rule** opens the editor pre-populated. Click **Create** to save it (disabled by default), then **Enable** and **Apply Now** in the rule's detail view to start tagging.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            loadingView
        case .ready(let suggestions):
            readyView(suggestions: suggestions)
        case .error(let message):
            errorView(message: message)
        }
    }

    private var loadingView: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("Analyzing recent tagging…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 40)
            Button("Try Again") {
                Task { await runAnalysis(initial: true) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func readyView(suggestions: [RuleSuggestion]) -> some View {
        let visible = suggestions.filter { !skipped.contains($0.id.uuidString) }
        if visible.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.green)
                Text("Nothing to suggest right now")
                    .font(.headline)
                Text("Tag a few more items and try again later.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("\(visible.count) suggestion\(visible.count == 1 ? "" : "s")")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    ForEach(visible) { suggestion in
                        SuggestionCard(
                            suggestion: suggestion,
                            onAdd: { addRule(suggestion) },
                            onSkip: { skipped.insert(suggestion.id.uuidString) }
                        )
                    }
                }
                .padding(14)
            }
        }
    }

    // MARK: - Actions

    /// `initial = true` on first open, where we want a full-screen
    /// loading state. Subsequent runs (refresh button, reset-skipped)
    /// pass `false` and keep the previous results visible behind a
    /// small spinner in the toolbar so the layout doesn't flash.
    private func runAnalysis(initial: Bool) async {
        if initial { phase = .loading }
        refreshing = !initial
        defer {
            refreshing = false
            dismissedFingerprintCount = SkippedSuggestionsStore.shared.fingerprints.count
        }
        do {
            // Pull both data sources: real audit log (post-instrumentation
            // tag changes) and a synthesized snapshot of every existing
            // item↔tag pairing. For an established library the snapshot
            // dwarfs the log and is what surfaces meaningful patterns;
            // the log gets richer as the user keeps tagging.
            let auditEvents = try await StashCLI.shared.recentTagEvents(limit: 0)
            let snapshotEvents = RuleSuggestionService.eventsFromItemSnapshot(items: store.items)
            let merged = RuleSuggestionService.mergeEvents(
                audit: auditEvents,
                snapshot: snapshotEvents
            )
            let dismissed = SkippedSuggestionsStore.shared.fingerprints
            let covered = RuleSuggestionService.tagsCoveredByEnabledRules(store.rules)
            let suggestions = try await RuleSuggestionService.shared.suggest(
                events: merged,
                coveredTags: covered,
                skipFingerprints: dismissed
            )
            phase = .ready(suggestions)
            // Reset the within-session skip set so reset+refresh
            // doesn't keep cards hidden through the in-memory `skipped`
            // filter. Persisted dismissals already filtered server-side.
            skipped = []
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    /// Hand the suggestion to the rule editor as a draft and dismiss
    /// the sheet. Nothing is written to rules.yaml here — the editor's
    /// Create button does that. The user reviews, tweaks if needed,
    /// then commits or cancels through the normal editor chrome.
    ///
    /// We persist the fingerprint to the skipped-store on click (not
    /// on editor commit) since we have no callback from the editor.
    /// If the user Cancels in the editor, the suggestion is hidden
    /// from future runs until they hit Reset Skipped — same trade-off
    /// as the explicit Skip button.
    private func addRule(_ suggestion: RuleSuggestion) {
        let rule = suggestion.toRule(enabled: false)
        store.startRuleDraft(from: rule)
        SkippedSuggestionsStore.shared.add(suggestion.fingerprint)
        dismiss()
    }
}

/// Single suggestion card. Renders the pattern statement, the
/// proposed rule's match/tag preview, a disclosure for supporting
/// items, and Add Rule / Skip buttons. "Add Rule" hands the
/// pre-populated proposal to the rule editor for review and commit;
/// nothing is saved until the editor's Create button fires.
private struct SuggestionCard: View {
    let suggestion: RuleSuggestion
    let onAdd: () -> Void
    let onSkip: () -> Void

    @Environment(StashStore.self) private var store
    @State private var supportingExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "wand.and.stars")
                    .foregroundStyle(.tint)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 8) {
                    Text(suggestion.pattern)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                    rulePreview
                    HStack(spacing: 4) {
                        Text("Tags:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(suggestion.addTags, id: \.self) { tag in
                            Text("#\(tag)")
                                .font(.caption.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.tint.opacity(0.18), in: Capsule())
                        }
                    }
                }
                Spacer()
            }

            DisclosureGroup(isExpanded: $supportingExpanded) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(suggestion.supportingItemIDs, id: \.self) { id in
                        if let item = store.items.first(where: { $0.id == id }) {
                            Button {
                                store.selectItemByID(id)
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: item.type.icon)
                                        .foregroundStyle(.secondary)
                                        .font(.caption)
                                    Text(item.title)
                                        .lineLimit(1)
                                        .foregroundStyle(.primary)
                                }
                            }
                            .buttonStyle(.plain)
                        } else {
                            Text("Item \(id.prefix(8))…")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.leading, 8)
                .padding(.top, 4)
            } label: {
                Text("\(suggestion.supportingItemIDs.count) supporting items")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Skip") { onSkip() }
                Button("Add Rule") { onAdd() }
                    .keyboardShortcut(.defaultAction)
                    .help("Open the rule editor pre-populated with this suggestion. Review, tweak, and click Create to save.")
            }
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
    }

    /// One labeled row per populated rule field. Each row aligns the
    /// label column so values line up cleanly across rows. Empty
    /// optional fields (no domain, no url_regex) are simply omitted.
    private var rulePreview: some View {
        VStack(alignment: .leading, spacing: 2) {
            previewRow(label: "name",      value: suggestion.name)
            if let d = suggestion.match.domain,   !d.isEmpty { previewRow(label: "domain",    value: d) }
            if let t = suggestion.match.type,     !t.isEmpty { previewRow(label: "type",      value: t) }
            if let r = suggestion.match.urlRegex, !r.isEmpty { previewRow(label: "url_regex", value: r) }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
    }

    private func previewRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(label):")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .trailing)
            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Persists fingerprints of suggestions the user has skipped so the
/// next analysis run doesn't re-propose them. UserDefaults-backed
/// because the data is small (<1KB), bounded by tag/domain
/// combinations, and not worth a file/sqlite schema.
@MainActor
final class SkippedSuggestionsStore {
    static let shared = SkippedSuggestionsStore()

    private let key = "RuleSuggestion.SkippedFingerprints.v1"

    var fingerprints: Set<String> {
        let arr = UserDefaults.standard.stringArray(forKey: key) ?? []
        return Set(arr)
    }

    func add(_ fingerprint: String) {
        var current = fingerprints
        current.insert(fingerprint)
        UserDefaults.standard.set(Array(current), forKey: key)
    }

    func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
