import AppKit
import SwiftUI

/// File menu → "Import Browser History…" multi-phase wizard.
/// Mirrors `ImportBookmarksSheet`'s UX but with two structural
/// differences:
///
/// 1. **Source is a browser** (chrome / edge / brave / arc /
///    vivaldi / opera / chromium / firefox / safari), and there's
///    no path field — discovery happens server-side via the
///    `history_path_for_browser` map. The since-N-days slider
///    bounds the result set instead.
/// 2. **Grouping is by date** (Today / Yesterday / Past 7 days /
///    Past 30 days / Older) rather than folder hierarchy. The
///    per-row UI (checkbox, DUPLICATE badge, tag pills, click-to-
///    reveal + button) is otherwise identical.
struct ImportHistorySheet: View {
    @Environment(StashStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    enum Phase {
        case source
        case discovering
        case review
        case importing
        case done
    }

    @State private var phase: Phase = .source
    @State private var error: String?

    // Phase 1
    @State private var browser: StashCLI.HistoryBrowser = .chrome
    @State private var sinceDays: Double = 15

    // Phase 3
    @State private var preview: StashCLI.BookmarkPreview?
    @State private var checkedURLs: Set<String> = []
    @State private var editedTags: [String: [String]] = [:]
    @State private var newTagDrafts: [String: String] = [:]
    @State private var addingTagFor: String?
    @State private var hideDuplicates: Bool = false

    // Shared-extras + collection (same as bookmarks sheet)
    @State private var collection: String = ""
    @State private var sharedExtraTags: [String] = ["history"]
    @State private var sharedExtraDraft: String = ""
    @State private var isAddingSharedExtra: Bool = false

    // Phase 5
    @State private var lastSummary: StashCLI.ImportSummary?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            phaseContent
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
            footerButtons
        }
        .padding(20)
        .frame(width: phase == .review || phase == .importing || phase == .done ? 820 : 540,
               height: phase == .review || phase == .importing || phase == .done ? 640 : 360)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.title3)
                .foregroundStyle(.tint)
            Text("Import Browser History")
                .font(.headline)
            Spacer()
            Text(phaseLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var phaseLabel: String {
        switch phase {
        case .source:       return "Step 1 of 3"
        case .discovering:  return "Reading history…"
        case .review:       return "Step 2 of 3 — Pick what to import"
        case .importing:    return "Importing…"
        case .done:         return "Done"
        }
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch phase {
        case .source:       sourcePhase
        case .discovering:  loadingBlock("Reading browser history…")
        case .review:       reviewPhase
        case .importing:    loadingBlock("Stashing selected visits…")
        case .done:         donePhase
        }
    }

    // MARK: - Phase 1: source + range

    private var sourcePhase: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text("Browser")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Browser", selection: $browser) {
                    Section("Chromium-based") {
                        Label("Chrome", systemImage: "globe").tag(StashCLI.HistoryBrowser.chrome)
                        Label("Edge", systemImage: "globe").tag(StashCLI.HistoryBrowser.edge)
                        Label("Brave", systemImage: "globe").tag(StashCLI.HistoryBrowser.brave)
                        Label("Arc", systemImage: "globe").tag(StashCLI.HistoryBrowser.arc)
                        Label("Vivaldi", systemImage: "globe").tag(StashCLI.HistoryBrowser.vivaldi)
                        Label("Opera", systemImage: "globe").tag(StashCLI.HistoryBrowser.opera)
                        Label("Chromium", systemImage: "globe").tag(StashCLI.HistoryBrowser.chromium)
                    }
                    Section("Other") {
                        Label("Firefox", systemImage: "flame").tag(StashCLI.HistoryBrowser.firefox)
                        Label("Safari", systemImage: "safari").tag(StashCLI.HistoryBrowser.safari)
                    }
                }
                .labelsHidden()
                .fixedSize()
                Spacer()
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Look back")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(sinceDays)) day\(Int(sinceDays) == 1 ? "" : "s")")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $sinceDays, in: 1...90, step: 1)
                Text("Default 15 days. Larger ranges discover more visits but the list gets long; pick what matches the period you actually want to curate.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if browser == .safari {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(.orange)
                    Text("Reading Safari history needs Full Disk Access on the `stash` CLI binary at ~/.local/bin/stash. If Discover fails with a permission error, grant access via System Settings → Privacy & Security → Full Disk Access.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    // MARK: - Phase 3: review (date buckets)

    private var reviewPhase: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let preview, !preview.bookmarks.isEmpty {
                let dupCount = preview.bookmarks.filter { $0.alreadyInStash }.count
                HStack(spacing: 12) {
                    Text("\(preview.bookmarks.count) visit\(preview.bookmarks.count == 1 ? "" : "s") in last \(Int(sinceDays)) day\(Int(sinceDays) == 1 ? "" : "s")")
                        .font(.callout)
                    if dupCount > 0 {
                        Toggle("Hide \(dupCount) already-stashed", isOn: $hideDuplicates)
                            .toggleStyle(.checkbox)
                            .font(.caption)
                    }
                    Spacer()
                    Text("\(checkedURLs.count) selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Select all") { selectAll() }
                        .buttonStyle(.link)
                    Button("Clear") { checkedURLs = [] }
                        .buttonStyle(.link)
                        .disabled(checkedURLs.isEmpty)
                }

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(flatRows, id: \.id) { row in
                            historyRow(row)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .background(.quaternary.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 6) {
                    Text("Apply to all picked items:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Extra tags")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            sharedExtraTagsEditor
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Collection")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            collectionField
                        }
                        .frame(width: 260)
                    }
                }
            } else {
                Text("No history found in the past \(Int(sinceDays)) days.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Date bucketing

    enum Bucket: Int, CaseIterable {
        case today, yesterday, pastWeek, pastMonth, older

        var title: String {
            switch self {
            case .today:     return "Today"
            case .yesterday: return "Yesterday"
            case .pastWeek:  return "Past 7 days"
            case .pastMonth: return "Past 30 days"
            case .older:     return "Older"
            }
        }

        var keyPrefix: String { "B/\(rawValue)" }
    }

    /// A flattened row — bucket header or leaf — pre-walked so
    /// SwiftUI doesn't have to compose a recursive opaque return
    /// type (the same limitation that bit the bookmarks tree).
    struct Row: Identifiable {
        enum Kind {
            case bucket(Bucket)
            case leaf(StashCLI.BookmarkPreviewItem)
        }
        let kind: Kind
        var id: String {
            switch kind {
            case .bucket(let b): return b.keyPrefix
            case .leaf(let bm):  return "L/" + bm.url
            }
        }
    }

    private var visibleBookmarks: [StashCLI.BookmarkPreviewItem] {
        guard let preview else { return [] }
        let items = hideDuplicates
            ? preview.bookmarks.filter { !$0.alreadyInStash }
            : preview.bookmarks
        return items
    }

    private var bookmarksByBucket: [(Bucket, [StashCLI.BookmarkPreviewItem])] {
        var by: [Bucket: [StashCLI.BookmarkPreviewItem]] = [:]
        let cal = Calendar.current
        let now = Date()
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        for item in visibleBookmarks {
            let bucket = bucketFor(item: item, now: now, calendar: cal, iso: isoFormatter)
            by[bucket, default: []].append(item)
        }
        // Sort within each bucket newest-first.
        for k in by.keys {
            by[k]?.sort { (a, b) in
                (a.createdAt ?? "") > (b.createdAt ?? "")
            }
        }
        return Bucket.allCases.compactMap { b in
            guard let items = by[b], !items.isEmpty else { return nil }
            return (b, items)
        }
    }

    private var flatRows: [Row] {
        var out: [Row] = []
        for (bucket, items) in bookmarksByBucket {
            out.append(Row(kind: .bucket(bucket)))
            for it in items { out.append(Row(kind: .leaf(it))) }
        }
        return out
    }

    private func bucketFor(
        item: StashCLI.BookmarkPreviewItem,
        now: Date,
        calendar: Calendar,
        iso: ISO8601DateFormatter
    ) -> Bucket {
        guard let raw = item.createdAt, let date = iso.date(from: raw) else {
            return .older
        }
        if calendar.isDateInToday(date) { return .today }
        if calendar.isDateInYesterday(date) { return .yesterday }
        let interval = now.timeIntervalSince(date)
        let sevenDays: TimeInterval = 7 * 24 * 60 * 60
        let thirtyDays: TimeInterval = 30 * 24 * 60 * 60
        if interval <= sevenDays  { return .pastWeek }
        if interval <= thirtyDays { return .pastMonth }
        return .older
    }

    // MARK: - Row rendering

    @ViewBuilder
    private func historyRow(_ row: Row) -> some View {
        switch row.kind {
        case .bucket(let b):
            let urls = bucketURLs(b)
            HStack(spacing: 6) {
                bucketCheckButton(bucket: b, urls: urls)
                Image(systemName: "calendar")
                    .foregroundStyle(.tint)
                Text(b.title)
                    .fontWeight(.semibold)
                Spacer()
                Text("\(urls.count)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(Color.primary.opacity(0.04))
        case .leaf(let bm):
            HStack(alignment: .top, spacing: 6) {
                Toggle("", isOn: urlBinding(bm.url))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                Image(systemName: "link")
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        if bm.alreadyInStash {
                            Text("STASHED")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.orange.opacity(0.25))
                                .foregroundStyle(.orange)
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                        }
                        Text(bm.title)
                            .font(.callout)
                            .lineLimit(1)
                            .foregroundStyle(bm.alreadyInStash ? .secondary : .primary)
                    }
                    Text(bm.url)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                tagPillsEditor(for: bm)
                    .frame(width: 280)
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 8)
            .padding(.leading, 18)
        }
    }

    private func bucketURLs(_ bucket: Bucket) -> [String] {
        for (b, items) in bookmarksByBucket where b == bucket {
            return items.map { $0.url }
        }
        return []
    }

    private func bucketCheckButton(bucket: Bucket, urls: [String]) -> some View {
        let checked = urls.filter { checkedURLs.contains($0) }.count
        let icon: String
        if checked == 0 { icon = "square" }
        else if checked == urls.count { icon = "checkmark.square.fill" }
        else { icon = "minus.square.fill" }
        return Button {
            if checked == urls.count {
                for u in urls { checkedURLs.remove(u) }
            } else {
                for u in urls { checkedURLs.insert(u) }
            }
        } label: {
            Image(systemName: icon)
                .foregroundStyle(checked > 0 ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        }
        .buttonStyle(.plain)
    }

    private func urlBinding(_ url: String) -> Binding<Bool> {
        Binding(
            get: { checkedURLs.contains(url) },
            set: { newValue in
                if newValue { checkedURLs.insert(url) } else { checkedURLs.remove(url) }
            }
        )
    }

    // MARK: - Tag pills (parallel to ImportBookmarksSheet)

    @ViewBuilder
    private func tagPillsEditor(for bm: StashCLI.BookmarkPreviewItem) -> some View {
        let tags = currentTags(for: bm)
        FlowLayout(spacing: 4) {
            ForEach(tags, id: \.self) { tag in
                tagPill(tag: tag, onRemove: { removeTag(tag, from: bm) })
            }
            if addingTagFor == bm.url {
                addTagField(for: bm)
            } else {
                addTagButton(for: bm)
            }
        }
    }

    private func addTagButton(for bm: StashCLI.BookmarkPreviewItem) -> some View {
        Button {
            newTagDrafts.removeAll()
            addingTagFor = bm.url
        } label: {
            Image(systemName: "plus.circle")
                .foregroundStyle(.secondary)
                .font(.callout)
        }
        .buttonStyle(.plain)
        .help("Add tag")
    }

    private func addTagField(for bm: StashCLI.BookmarkPreviewItem) -> some View {
        let binding = Binding<String>(
            get: { newTagDrafts[bm.url] ?? "" },
            set: { value in
                if value.contains(",") {
                    for part in value.split(separator: ",") {
                        let n = normalizeTag(String(part))
                        if !n.isEmpty {
                            var current = currentTags(for: bm)
                            if !current.contains(n) {
                                current.append(n)
                                editedTags[bm.url] = current
                            }
                        }
                    }
                    newTagDrafts[bm.url] = ""
                } else {
                    newTagDrafts[bm.url] = value
                }
            }
        )
        return FilterField(
            placeholder: "new tag",
            text: binding,
            autoFocus: true,
            onSubmit: {
                commitNewTag(bm)
                addingTagFor = nil
            },
            onKey: { key in
                switch key {
                case .tab:
                    commitNewTag(bm)
                    addingTagFor = nil
                    return true
                case .escape:
                    newTagDrafts[bm.url] = ""
                    addingTagFor = nil
                    return true
                default:
                    return false
                }
            },
            onEndEditing: {
                if addingTagFor == bm.url {
                    commitNewTag(bm)
                    addingTagFor = nil
                }
            }
        )
        .frame(width: 80)
    }

    private func tagPill(tag: String, onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: 3) {
            Text(tag)
                .font(.caption)
                .lineLimit(1)
            Button { onRemove() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 6)
        .padding(.trailing, 3)
        .padding(.vertical, 2)
        .background(Color.accentColor.opacity(0.18), in: Capsule())
    }

    private func currentTags(for bm: StashCLI.BookmarkPreviewItem) -> [String] {
        editedTags[bm.url] ?? bm.defaultTags
    }

    private func removeTag(_ tag: String, from bm: StashCLI.BookmarkPreviewItem) {
        var current = currentTags(for: bm)
        current.removeAll { $0 == tag }
        editedTags[bm.url] = current
    }

    private func commitNewTag(_ bm: StashCLI.BookmarkPreviewItem) {
        guard let draft = newTagDrafts[bm.url] else { return }
        let n = normalizeTag(draft)
        guard !n.isEmpty else {
            newTagDrafts[bm.url] = ""
            return
        }
        var current = currentTags(for: bm)
        if !current.contains(n) {
            current.append(n)
            editedTags[bm.url] = current
        }
        newTagDrafts[bm.url] = ""
    }

    private func normalizeTag(_ raw: String) -> String {
        let lowered = raw.lowercased()
        var out = ""
        var lastWasHyphen = false
        for c in lowered {
            if c.isLetter || c.isNumber {
                out.append(c)
                lastWasHyphen = false
            } else if !lastWasHyphen, !out.isEmpty {
                out.append("-")
                lastWasHyphen = true
            }
        }
        if out.hasSuffix("-") { out.removeLast() }
        return out
    }

    private func selectAll() {
        guard let items = preview?.bookmarks else { return }
        checkedURLs = Set(items.filter { !$0.alreadyInStash }.map { $0.url })
    }

    // MARK: - Shared extras + collection

    @ViewBuilder
    private var sharedExtraTagsEditor: some View {
        FlowLayout(spacing: 4) {
            ForEach(sharedExtraTags, id: \.self) { tag in
                tagPill(tag: tag, onRemove: {
                    sharedExtraTags.removeAll { $0 == tag }
                })
            }
            if isAddingSharedExtra {
                FilterField(
                    placeholder: "new tag",
                    text: Binding(
                        get: { sharedExtraDraft },
                        set: { value in
                            if value.contains(",") {
                                for part in value.split(separator: ",") {
                                    let n = normalizeTag(String(part))
                                    if !n.isEmpty, !sharedExtraTags.contains(n) {
                                        sharedExtraTags.append(n)
                                    }
                                }
                                sharedExtraDraft = ""
                            } else {
                                sharedExtraDraft = value
                            }
                        }
                    ),
                    autoFocus: true,
                    onSubmit: { commitSharedExtraDraft() },
                    onKey: { key in
                        switch key {
                        case .tab:    commitSharedExtraDraft(); return true
                        case .escape: sharedExtraDraft = ""; isAddingSharedExtra = false; return true
                        default:      return false
                        }
                    },
                    onEndEditing: {
                        if isAddingSharedExtra { commitSharedExtraDraft() }
                    }
                )
                .frame(width: 100)
            } else {
                Button { isAddingSharedExtra = true } label: {
                    Image(systemName: "plus.circle")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                .buttonStyle(.plain)
                .help("Add tag applied to every picked visit")
            }
        }
    }

    private func commitSharedExtraDraft() {
        let n = normalizeTag(sharedExtraDraft)
        if !n.isEmpty, !sharedExtraTags.contains(n) {
            sharedExtraTags.append(n)
        }
        sharedExtraDraft = ""
        isAddingSharedExtra = false
    }

    @ViewBuilder
    private var collectionField: some View {
        HStack(spacing: 6) {
            FilterField(
                placeholder: "(none)",
                text: $collection
            )
            Menu {
                Button("(none)") { collection = "" }
                if !store.collections.isEmpty {
                    Divider()
                    ForEach(store.collections) { col in
                        Button(col.name) { collection = col.name }
                    }
                }
            } label: {
                Image(systemName: "chevron.down.circle")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Pick an existing collection or type a new name")
        }
    }

    // MARK: - Done state

    @ViewBuilder
    private var donePhase: some View {
        if let s = lastSummary {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(doneText(s))
                        .font(.callout)
                        .fontWeight(.medium)
                }
                if let errs = s.errors, !errs.isEmpty {
                    Text("\(errs.count) error\(errs.count == 1 ? "" : "s") during commit:")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(errs, id: \.self) { e in
                                Text("• \(e)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.orange)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(maxHeight: 140)
                }
                Text("Re-running for the same window later still works — already-stashed visits are skipped by URL.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func doneText(_ s: StashCLI.ImportSummary) -> String {
        var parts: [String] = []
        if s.imported > 0 { parts.append("\(s.imported) imported") }
        if s.skipped > 0 { parts.append("\(s.skipped) skipped (already in stash)") }
        if parts.isEmpty { parts.append("No changes") }
        return parts.joined(separator: ", ")
    }

    // MARK: - Footer

    private var footerButtons: some View {
        HStack {
            Spacer()
            switch phase {
            case .source:
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Discover…") { runDiscover() }
                    .keyboardShortcut(.defaultAction)
            case .review:
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Back") { phase = .source }
                Button("Import \(checkedURLs.count)…") { runApply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(checkedURLs.isEmpty)
            case .done:
                Button("Import More") { phase = .review }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            case .discovering, .importing:
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(true)
            }
        }
    }

    // MARK: - Loading

    private func loadingBlock(_ msg: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(msg).font(.callout)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    // MARK: - Actions

    private func runDiscover() {
        error = nil
        phase = .discovering
        let days = Int(sinceDays)
        Task {
            do {
                let p = try await StashCLI.shared.previewBrowserHistory(browser: browser, sinceDays: days)
                await MainActor.run {
                    preview = p
                    checkedURLs = []
                    editedTags = [:]
                    newTagDrafts = [:]
                    phase = .review
                }
            } catch {
                await MainActor.run {
                    self.error = "Discover failed: \(error.localizedDescription)"
                    self.phase = .source
                }
            }
        }
    }

    private func runApply() {
        for url in Array(newTagDrafts.keys) {
            if let bm = preview?.bookmarks.first(where: { $0.url == url }) {
                commitNewTag(bm)
            }
        }
        if isAddingSharedExtra { commitSharedExtraDraft() }

        guard let preview else { return }
        let coll = collection.trimmingCharacters(in: .whitespaces)
        let sharedExtras = sharedExtraTags

        let items: [StashCLI.BookmarkApplyItem] = preview.bookmarks
            .filter { checkedURLs.contains($0.url) }
            .map { bm in
                var tagSet = Set(editedTags[bm.url] ?? bm.defaultTags)
                for t in sharedExtras { tagSet.insert(t) }
                return StashCLI.BookmarkApplyItem(
                    url: bm.url,
                    title: bm.title,
                    tags: Array(tagSet).sorted(),
                    createdAt: bm.createdAt,
                    notes: bm.notes
                )
            }
        let manifest = StashCLI.BookmarkApplyManifest(
            collection: coll.isEmpty ? nil : coll,
            items: items
        )

        error = nil
        phase = .importing
        Task {
            do {
                let summary = try await StashCLI.shared.applyBookmarkManifest(manifest)
                await MainActor.run {
                    lastSummary = summary
                    store.loadAll()
                    for url in items.map(\.url) { checkedURLs.remove(url) }
                    phase = .done
                }
            } catch {
                await MainActor.run {
                    self.error = "Import failed: \(error.localizedDescription)"
                    self.phase = .review
                }
            }
        }
    }
}
