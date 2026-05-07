import SwiftUI
import AppKit

/// Create- or Edit-a-Smart-Collection sheet. Saves a live saved
/// search via `stash search save --live`, which the sidebar then
/// renders under "Smart Collections" with auto-refresh on
/// `.stashDidIngest`. Since `stash search save` is itself an upsert
/// (ON CONFLICT DO UPDATE), the same call handles both creation and
/// in-place editing — we just seed `@State` from the existing
/// SavedSearch when `editing` is non-nil.
struct SmartCollectionSheet: View {
    @Environment(StashStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// When non-nil, the sheet is editing this existing saved search.
    /// Name field is locked in edit mode (renaming a saved search
    /// would orphan the old DB row instead of moving it); all other
    /// filter dimensions are mutable.
    let editing: SavedSearch?

    @State private var name: String
    @State private var typeFilter: String
    @State private var tagsText: String
    @State private var excludeTagsText: String
    @State private var collection: String
    /// Unified text-search field. Contents are auto-classified at save
    /// time: input with regex metacharacters (`^$\\[](){}*+?|{}`) is
    /// passed through as RE2; plain text gets escaped so it matches
    /// literally. A leading `!` negates either path. The wire format
    /// is always a regex string — no separate FTS5 path on the Mac.
    @State private var searchText: String
    @State private var untagged: Bool
    @State private var recentValue: String
    @State private var recentUnit: RecentUnit
    @State private var error: String?

    // Popover-on-focus for the unified search/regex field. Same
    // pattern as the rule editor's regex condition: focus arrival
    // (becomeFirstResponder, NOT controlTextDidBeginEditing) sets the
    // flag, an NSEvent click-outside monitor resigns first responder
    // when the user clicks anywhere outside the field.
    @State private var showRegexGuide: Bool = false
    @State private var regexClickMonitor: Any?

    init(editing: SavedSearch? = nil) {
        self.editing = editing
        let f = editing?.filter
        _name = State(initialValue: editing?.name ?? "")
        _typeFilter = State(initialValue: f?.type ?? "")
        _tagsText = State(initialValue: (f?.tags ?? []).joined(separator: ", "))
        _excludeTagsText = State(initialValue: (f?.excludeTags ?? []).joined(separator: ", "))
        _collection = State(initialValue: f?.collection ?? "")
        // Edit mode: prefer the saved regex (the new path); fall back
        // to the legacy top-level FTS query if that's what was stored.
        // Both render in the unified field.
        let initialSearch = (f?.regex?.isEmpty == false ? f!.regex! : (editing?.query ?? ""))
        _searchText = State(initialValue: initialSearch)
        _untagged = State(initialValue: f?.untagged ?? false)
        let (val, unit) = SmartCollectionSheet.splitRecent(f?.recent ?? "")
        _recentValue = State(initialValue: val)
        _recentUnit = State(initialValue: unit)
    }

    /// Split a stored "7d" / "2w" / "6h" string back into its numeric
    /// part and unit so the sheet's two-field UI can render it. Empty
    /// or unparseable strings come back as ("", .days).
    private static func splitRecent(_ spec: String) -> (String, RecentUnit) {
        let s = spec.trimmingCharacters(in: .whitespaces)
        guard let last = s.last else { return ("", .days) }
        let unit: RecentUnit
        switch last {
        case "h": unit = .hours
        case "d": unit = .days
        case "w": unit = .weeks
        default:  return ("", .days)
        }
        let head = String(s.dropLast())
        guard !head.isEmpty, Int(head) != nil else { return ("", .days) }
        return (head, unit)
    }

    /// Time-window unit picker for the relative `recent` filter.
    /// Maps to the duration shorthand the CLI accepts (`d` / `w` /
    /// `h`); we always send a string like "7d" so the spec
    /// re-resolves on every query.
    private enum RecentUnit: String, CaseIterable, Identifiable {
        case hours = "h"
        case days = "d"
        case weeks = "w"
        var id: String { rawValue }
        var label: String {
            switch self {
            case .hours: return "hours"
            case .days:  return "days"
            case .weeks: return "weeks"
            }
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespaces)
    }

    private var nameCollides: Bool {
        let n = trimmedName
        guard !n.isEmpty else { return false }
        // In edit mode, the row's own name doesn't count as a
        // collision (re-saving with the same name is the upsert path).
        if let editing, editing.name == n { return false }
        return store.savedSearches.contains(where: { $0.name == n })
    }

    private var canSave: Bool {
        guard !trimmedName.isEmpty, !nameCollides else { return false }
        // At least one filter must be set — an unconstrained Smart
        // Collection would just mirror All Items and waste a slot.
        return !parsedTags().isEmpty
            || !parsedExcludeTags().isEmpty
            || untagged
            || !typeFilter.isEmpty
            || !collection.trimmingCharacters(in: .whitespaces).isEmpty
            || !searchText.trimmingCharacters(in: .whitespaces).isEmpty
            || !recentSpec().isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(editing == nil ? "New Smart Collection" : "Edit Smart Collection")
                    .font(.headline)

                nameSection
                typeSection
                tagsSection
                collectionSection
                searchSection
                recentSection

                if let error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(20)
        }
        .frame(width: 480, height: 560)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
    }

    // MARK: - Sections

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Name")
                .font(.caption)
                .foregroundStyle(.secondary)
            FilterField(
                placeholder: "e.g. unread-videos",
                text: $name,
                autoFocus: editing == nil
            )
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.quaternary.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            if nameCollides {
                Text("A saved search named “\(trimmedName)” already exists.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var typeSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Item type (optional)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("", selection: $typeFilter) {
                Text("Any").tag("")
                Text("URL").tag("link")
                Text("Snippet").tag("snippet")
                Text("File").tag("file")
                Text("Image").tag("image")
                Text("Email").tag("email")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $untagged) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Only untagged items")
                    Text("Show items with zero tags. Overrides include/exclude tag filters below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Include tags (comma-separated, optional)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                MultiTagField(text: $tagsText, allTags: store.tags)
                    .opacity(untagged ? 0.4 : 1)
                    .disabled(untagged)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Exclude tags (comma-separated, optional)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                MultiTagField(text: $excludeTagsText, allTags: store.tags)
                    .opacity(untagged ? 0.4 : 1)
                    .disabled(untagged)
            }
        }
    }

    private var collectionSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Collection (optional)")
                .font(.caption)
                .foregroundStyle(.secondary)
            FilterField(
                placeholder: "e.g. work",
                text: $collection
            )
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.quaternary.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
    }

    /// Unified search field. Plain words match as literal substrings;
    /// inputs containing regex metacharacters are passed through as
    /// RE2 patterns. A leading `!` negates either path. Match scope:
    /// title + notes + URL + extracted text.
    private var searchSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Search text (optional)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if SmartCollectionSheet.looksLikeRegex(searchText) {
                    Text("regex detected")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.blue)
                }
                Spacer()
            }
            FilterField(
                placeholder: "kubernetes  ·  ^https://github\\.com/  ·  !youtube",
                text: $searchText,
                onBeginEditing: {
                    // Defer one runloop tick — SwiftUI's popover
                    // lifecycle on macOS doesn't attach reliably when
                    // the show signal is written synchronously from
                    // inside becomeFirstResponder.
                    DispatchQueue.main.async {
                        showRegexGuide = true
                    }
                },
                onEndEditing: {
                    showRegexGuide = false
                }
            )
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.quaternary.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .popover(
                isPresented: Binding(
                    get: { showRegexGuide },
                    set: { newValue in
                        if !newValue { showRegexGuide = false }
                    }
                ),
                attachmentAnchor: .rect(.bounds),
                arrowEdge: .top
            ) {
                RegexGuideView()
            }
            Text("Plain words match anywhere in title/notes/URL/extracted text. Use `^` / `$` for anchors, `!` prefix to negate.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .onChange(of: showRegexGuide) { _, newValue in
            if newValue {
                installRegexClickMonitor()
            } else {
                removeRegexClickMonitor()
            }
        }
        .onDisappear { removeRegexClickMonitor() }
    }

    /// Heuristic for "this input is regex syntax" — presence of any
    /// RE2 metacharacter (excluding `.`, which appears too often in
    /// plain text like URLs to be a useful trigger). The leading `!`
    /// negation marker is stripped before checking. Used for the
    /// "regex detected" hint and for the literal-vs-regex routing in
    /// `commit()`.
    static func looksLikeRegex(_ s: String) -> Bool {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("!") {
            t = String(t.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        let metas: Set<Character> = ["^", "$", "\\", "[", "]", "(", ")", "*", "+", "?", "|", "{", "}"]
        return t.contains(where: { metas.contains($0) })
    }

    /// Same click-outside-to-resign monitor pattern as RuleDetailView's
    /// regex guide. Without it, clicking outside dismisses the popover
    /// (the binding fires) but the field keeps focus, so the next
    /// click back into the field doesn't re-fire `becomeFirstResponder`
    /// and the popover stays hidden.
    private func installRegexClickMonitor() {
        guard regexClickMonitor == nil else { return }
        regexClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            guard let window = event.window,
                  let editor = window.firstResponder as? NSText,
                  let field = editor.delegate as? NSTextField else {
                return event
            }
            let frameInWindow = field.superview?.convert(field.frame, to: nil) ?? field.frame
            if !frameInWindow.contains(event.locationInWindow) {
                DispatchQueue.main.async {
                    window.makeFirstResponder(nil)
                }
            }
            return event
        }
    }

    private func removeRegexClickMonitor() {
        if let m = regexClickMonitor {
            NSEvent.removeMonitor(m)
            regexClickMonitor = nil
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Captured within (optional)")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                FilterField(
                    placeholder: "e.g. 7",
                    text: $recentValue
                )
                .frame(width: 80)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.quaternary.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 5))
                Picker("", selection: $recentUnit) {
                    ForEach(RecentUnit.allCases) { u in
                        Text(u.label).tag(u)
                    }
                }
                .labelsHidden()
                .frame(width: 110)
                Spacer()
            }
            Text("Resolved every time the collection runs — “7 days” always means “the last 7 days from today.”")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func parsedTags() -> [String] {
        splitCSV(tagsText)
    }

    private func parsedExcludeTags() -> [String] {
        splitCSV(excludeTagsText)
    }

    private func splitCSV(_ s: String) -> [String] {
        s.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Compose the relative time spec the CLI accepts (e.g. "7d", "2w").
    /// Returns "" when the value field is empty or not a positive int —
    /// we deliberately reject zero and negatives because they'd resolve
    /// to "everything since the beginning of time" or future, neither
    /// useful as a smart-collection filter.
    private func recentSpec() -> String {
        let trimmed = recentValue.trimmingCharacters(in: .whitespaces)
        guard let n = Int(trimmed), n > 0 else { return "" }
        return "\(n)\(recentUnit.rawValue)"
    }

    private func commit() {
        let trimmedCollection = collection.trimmingCharacters(in: .whitespaces)
        let recent = recentSpec()
        let includeTags = untagged ? nil : (parsedTags().isEmpty ? nil : parsedTags())
        let excludeTags = untagged ? nil : (parsedExcludeTags().isEmpty ? nil : parsedExcludeTags())
        let regexPattern = SmartCollectionSheet.normalizeSearch(searchText)

        let filter = SavedSearch.SearchFilter(
            type: typeFilter.isEmpty ? nil : typeFilter,
            tags: includeTags,
            excludeTags: excludeTags,
            untagged: untagged ? true : nil,
            collection: trimmedCollection.isEmpty ? nil : trimmedCollection,
            recent: recent.isEmpty ? nil : recent,
            regex: regexPattern.isEmpty ? nil : regexPattern,
            limit: nil
        )
        // Top-level `query` (FTS5) is unused on the Mac now — the
        // unified search field always routes through the regex
        // filter, which is applied post-SQL and works regardless of
        // whether ListItems or SearchItems is the run path.
        // `originalName` lets the store detect a rename (when in
        // edit mode and the user changed the name field) and call
        // `stash search rename` before the upsert.
        store.saveSearchFromMac(
            name: trimmedName,
            originalName: editing?.name,
            query: "",
            filter: filter
        ) { err in
            if let err {
                self.error = err
            } else {
                dismiss()
            }
        }
    }

    /// Convert the unified search field into a regex pattern. Plain
    /// words are escaped so `.` / `+` / etc. match literally; inputs
    /// with regex metacharacters pass through verbatim. The leading
    /// `!` negation marker (used by Go's applyRegexFilter) is preserved
    /// either way so users can write `!github` or `!^http://`.
    static func normalizeSearch(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "" }
        var negate = false
        var body = trimmed
        if body.hasPrefix("!") {
            negate = true
            body = String(body.dropFirst()).trimmingCharacters(in: .whitespaces)
            if body.isEmpty { return "" }
        }
        if !looksLikeRegex(body) {
            body = escapeRegexLiteral(body)
        }
        return negate ? "!" + body : body
    }

    private static func escapeRegexLiteral(_ s: String) -> String {
        let specials: Set<Character> = ["\\", ".", "^", "$", "|", "(", ")", "[", "]", "{", "}", "*", "+", "?"]
        var out = ""
        out.reserveCapacity(s.count)
        for c in s {
            if specials.contains(c) {
                out.append("\\")
            }
            out.append(c)
        }
        return out
    }
}
