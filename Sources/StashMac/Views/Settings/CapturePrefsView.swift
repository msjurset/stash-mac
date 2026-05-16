import SwiftUI
import AppKit

/// "Capture" tab in Settings. Hosts the URL-exclusions editor —
/// rules that rewrite or clear the URL field on items captured
/// from transient session sources (Gemini chats, OAuth flows,
/// Slack thread URLs, etc.). Rules persist in the CLI's
/// `~/.config/stash/config.toml` via `stash config exclusions`
/// subcommands.
struct CapturePrefsView: View {
    @State private var rules: [StashCLI.URLExclusion] = []
    @State private var isLoading: Bool = true
    @State private var error: String?

    // Edit-row state — null when no row is being edited.
    @State private var draft: StashCLI.URLExclusion?
    /// Original pattern of the rule being edited. Nil when the
    /// draft is a brand-new rule (not yet persisted). Tracked
    /// separately from `draft.pattern` because the user can edit
    /// the pattern field, which would otherwise drop the edit-row
    /// rendering the moment they typed a different character.
    @State private var editingOriginalPattern: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            ruleList
            Spacer(minLength: 0)
            footerHints
        }
        .padding(20)
        .task { await load() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("URL exclusions")
                .font(.headline)
            Text("Rules that rewrite the URL field on captured items. The capture itself still happens — only what gets stored in the URL column is redacted. Useful for transient session URLs (Gemini chats, OAuth flows, Slack archives with auth tokens) that can't be re-visited.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Rule list

    @ViewBuilder
    private var ruleList: some View {
        if isLoading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading…").font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("\(rules.count) rule\(rules.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        startAddDraft()
                    } label: {
                        Label("Add rule", systemImage: "plus")
                    }
                }

                if let error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rules) { rule in
                            ruleRow(rule)
                            Divider()
                        }
                        if let d = draft, editingOriginalPattern == nil {
                            editRow(for: d)
                        } else if rules.isEmpty {
                            Text("No rules yet.")
                                .font(.callout)
                                .foregroundStyle(.tertiary)
                                .padding(.vertical, 12)
                                .padding(.horizontal, 10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: 280)
                .background(.quaternary.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    @ViewBuilder
    private func ruleRow(_ rule: StashCLI.URLExclusion) -> some View {
        // While this rule is being edited, swap it for the edit row.
        // Uses `editingOriginalPattern` (stable across edits) rather
        // than `draft.pattern` (changes as user types).
        if let d = draft, editingOriginalPattern == rule.pattern {
            editRow(for: d, existingPattern: rule.pattern)
        } else {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(rule.pattern)
                        .font(.callout.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(humanSummary(for: rule))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("Edit") { startEditDraft(rule) }
                    .buttonStyle(.borderless)
                Button {
                    Task { await remove(rule) }
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Remove rule")
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
        }
    }

    /// Inline edit row, used for both new-rule and existing-rule
    /// edits. `existingPattern` is the unchanged identifier when
    /// editing — needed because the user may rename the pattern,
    /// and we have to delete-by-old-name + add-by-new-name on the
    /// CLI side.
    @ViewBuilder
    private func editRow(for rule: StashCLI.URLExclusion, existingPattern: String? = nil) -> some View {
        let patternBinding = Binding<String>(
            get: { draft?.pattern ?? "" },
            set: { newPattern in
                draft = StashCLI.URLExclusion(
                    pattern: newPattern,
                    match: draft?.match ?? "domain",
                    behavior: draft?.behavior ?? "domain"
                )
            }
        )
        let matchBinding = Binding<String>(
            get: { draft?.match ?? "domain" },
            set: { draft = StashCLI.URLExclusion(pattern: draft?.pattern ?? "", match: $0, behavior: draft?.behavior ?? "domain") }
        )
        let behaviorBinding = Binding<String>(
            get: { draft?.behavior ?? "domain" },
            set: { draft = StashCLI.URLExclusion(pattern: draft?.pattern ?? "", match: draft?.match ?? "domain", behavior: $0) }
        )
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                FilterField(
                    placeholder: matchBinding.wrappedValue == "regex"
                        ? "RE2 pattern, e.g. ^https://chatgpt\\.com/c/"
                        : "Domain, e.g. gemini.google.com or *.googleusercontent.com",
                    text: patternBinding
                )
                .frame(maxWidth: .infinity)
            }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Match").font(.caption2).foregroundStyle(.tertiary)
                    Picker("", selection: matchBinding) {
                        Text("Domain").tag("domain")
                        Text("Regex").tag("regex")
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Behavior").font(.caption2).foregroundStyle(.tertiary)
                    Picker("", selection: behaviorBinding) {
                        Text("Keep domain").tag("domain")
                        Text("Clear URL").tag("clear")
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                }
                Spacer()
                Button("Cancel") { draft = nil; editingOriginalPattern = nil }
                    .keyboardShortcut(.cancelAction)
                Button(existingPattern == nil ? "Add" : "Save") {
                    Task { await saveDraft(replacing: existingPattern) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled((draft?.pattern ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(Color.accentColor.opacity(0.06))
    }

    private func humanSummary(for r: StashCLI.URLExclusion) -> String {
        let m = r.match.lowercased()
        let b = r.behavior.lowercased()
        let matchPhrase: String
        switch m {
        case "regex":  matchPhrase = "Regex match"
        default:       matchPhrase = "Domain match"
        }
        let behaviorPhrase: String
        switch b {
        case "clear":  behaviorPhrase = "clear URL"
        default:       behaviorPhrase = "keep scheme + host, drop path"
        }
        return "\(matchPhrase) → \(behaviorPhrase)"
    }

    // MARK: - Footer hints

    private var footerHints: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Examples:")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("• gemini.google.com → Keep domain (image picks store gemini.google.com instead of the session URL)")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text("• *.slack.com → Keep domain (auth-token thread links collapse to the workspace domain)")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text("• ^https://accounts\\.google\\.com/ → Clear URL (OAuth landing pages have no re-visit value)")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Actions

    private func load() async {
        isLoading = true
        error = nil
        do {
            let r = try await StashCLI.shared.listURLExclusions()
            await MainActor.run {
                rules = r
                isLoading = false
            }
        } catch {
            await MainActor.run {
                self.error = "Load failed: \(error.localizedDescription)"
                self.isLoading = false
            }
        }
    }

    private func startAddDraft() {
        draft = StashCLI.URLExclusion(pattern: "", match: "domain", behavior: "domain")
        editingOriginalPattern = nil
    }

    private func startEditDraft(_ rule: StashCLI.URLExclusion) {
        draft = rule
        editingOriginalPattern = rule.pattern
    }

    private func saveDraft(replacing oldPattern: String?) async {
        guard let d = draft else { return }
        let trimmed = d.pattern.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let toSave = StashCLI.URLExclusion(pattern: trimmed, match: d.match, behavior: d.behavior)
        error = nil
        do {
            // Rename case — remove the old row first so we don't
            // end up with both.
            if let oldPattern, oldPattern != trimmed {
                try await StashCLI.shared.removeURLExclusion(pattern: oldPattern)
            }
            try await StashCLI.shared.addURLExclusion(toSave)
            await MainActor.run {
                draft = nil
                editingOriginalPattern = nil
            }
            await load()
        } catch {
            await MainActor.run {
                self.error = "Save failed: \(error.localizedDescription)"
            }
        }
    }

    private func remove(_ rule: StashCLI.URLExclusion) async {
        error = nil
        do {
            try await StashCLI.shared.removeURLExclusion(pattern: rule.pattern)
            await load()
        } catch {
            await MainActor.run {
                self.error = "Remove failed: \(error.localizedDescription)"
            }
        }
    }
}

private extension StashCLI.URLExclusion {
    /// Returns a copy with the pattern replaced. Used by the
    /// inline-edit binding chain.
    func withPattern(_ newPattern: String) -> StashCLI.URLExclusion {
        StashCLI.URLExclusion(pattern: newPattern, match: match, behavior: behavior)
    }
}
