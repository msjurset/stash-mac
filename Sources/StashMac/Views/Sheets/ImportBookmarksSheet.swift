import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// File menu → "Import Bookmarks…" multi-phase wizard.
///
///   1. **Source** — pick Chrome / Firefox / HTML, auto-discover or
///      override the file path.
///   2. **Discovering** — calls `stash import <src> --dry-run --json`.
///   3. **Review** — hierarchical tree of the bookmark file with
///      tri-state folder checkboxes, per-item checkbox, and inline
///      per-item tag editor. Shared "Add to collection" /
///      "Extra tags on every imported item" fields apply to the
///      curated subset on commit.
///   4. **Importing** — pipes the curated manifest into
///      `stash import apply --json`.
///   5. **Done** — summary; user can click "Import More" to return
///      to Review with the already-imported items pre-unchecked
///      (dedup happens on the CLI side regardless, but pre-unchecking
///      keeps the list tidy for round-2 picking).
///
/// The Mac side only handles UI + selection state; parsing and
/// commit both run through the CLI so all import policy
/// (dedup-by-URL, date conversion, folder normalization) lives in
/// one place.
struct ImportBookmarksSheet: View {
    @Environment(StashStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    // MARK: - Phase state

    enum Phase {
        case source        // pick source + path
        case discovering   // calling --dry-run --json
        case review        // tree picker, tag editing
        case importing     // calling import apply --json
        case done          // result summary
    }

    @State private var phase: Phase = .source
    @State private var error: String?

    // Phase 1
    @State private var source: StashCLI.BookmarkSource = .chrome
    @State private var path: String = ""
    @State private var collection: String = ""
    /// Shared tags applied to every picked item. Uses the same
    /// pill-based UI as per-row tags so the user can pick a base
    /// set with the same gestures (click +, type, Enter / Tab to
    /// commit, × to remove).
    @State private var sharedExtraTags: [String] = ["imported", "browser-import"]
    @State private var sharedExtraDraft: String = ""
    @State private var isAddingSharedExtra: Bool = false

    // Phase 3 selection state. Keyed by bookmark URL since the CLI
    // dedups by URL too and URL is the natural primary key for the
    // import manifest.
    @State private var preview: StashCLI.BookmarkPreview?
    @State private var checkedURLs: Set<String> = []
    /// Per-URL tag overrides. Absent = use the bookmark's
    /// `defaultTags`; present = user edited.
    @State private var editedTags: [String: [String]] = [:]
    /// In-progress "add a new tag" text per row. Committed to
    /// `editedTags` (after normalization) on Enter or comma.
    @State private var newTagDrafts: [String: String] = [:]
    /// URL of the row whose "+" was clicked — when set, that row
    /// renders a focused text field instead of the plus button.
    /// Enter/Tab/click-away commit; Escape cancels.
    @State private var addingTagFor: String?
    /// When true, hide rows whose `alreadyInStash` is true (and
    /// any folders that end up empty as a result).
    @State private var hideDuplicates: Bool = false

    // Phase 5
    @State private var lastSummary: StashCLI.ImportSummary?

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            phaseContent
            if let error {
                errorBlock(error)
            }
            Spacer(minLength: 0)
            footerButtons
        }
        .padding(20)
        .frame(width: phase == .review || phase == .importing || phase == .done ? 820 : 540,
               height: phase == .review || phase == .importing || phase == .done ? 640 : 500)
        .onAppear { recomputePath() }
        .onChange(of: source) { _, _ in
            error = nil
            recomputePath()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "bookmark")
                .font(.title3)
                .foregroundStyle(.tint)
            Text("Import Bookmarks")
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
        case .discovering:  return "Discovering…"
        case .review:       return "Step 2 of 3 — Pick what to import"
        case .importing:    return "Importing…"
        case .done:         return "Done"
        }
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch phase {
        case .source:       sourcePhase
        case .discovering:  loadingBlock("Reading bookmark file…")
        case .review:       reviewPhase
        case .importing:    loadingBlock("Importing selected bookmarks…")
        case .done:         donePhase
        }
    }

    // MARK: - Phase 1: source

    private var sourcePhase: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text("Source")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Source", selection: $source) {
                    // Order: native first, Chromium-family clones
                    // second, services third, generic last. Helps the
                    // user find their browser by visual scan.
                    Section("Native") {
                        Label("Safari", systemImage: "safari").tag(StashCLI.BookmarkSource.safari)
                    }
                    Section("Chromium-based") {
                        Label("Chrome", systemImage: "globe").tag(StashCLI.BookmarkSource.chrome)
                        Label("Edge", systemImage: "globe").tag(StashCLI.BookmarkSource.edge)
                        Label("Brave", systemImage: "globe").tag(StashCLI.BookmarkSource.brave)
                        Label("Arc", systemImage: "globe").tag(StashCLI.BookmarkSource.arc)
                        Label("Vivaldi", systemImage: "globe").tag(StashCLI.BookmarkSource.vivaldi)
                        Label("Opera", systemImage: "globe").tag(StashCLI.BookmarkSource.opera)
                        Label("Chromium", systemImage: "globe").tag(StashCLI.BookmarkSource.chromium)
                    }
                    Section("Other") {
                        Label("Firefox", systemImage: "flame").tag(StashCLI.BookmarkSource.firefox)
                    }
                    Section("Services") {
                        Label("Pinterest (CSV)", systemImage: "pin").tag(StashCLI.BookmarkSource.pinterest)
                        Label("Raindrop.io (CSV)", systemImage: "drop").tag(StashCLI.BookmarkSource.raindrop)
                        Label("Pocket (HTML export)", systemImage: "tray").tag(StashCLI.BookmarkSource.pocket)
                    }
                    Section("Generic") {
                        Label("HTML export (Netscape format)", systemImage: "doc.text").tag(StashCLI.BookmarkSource.netscapeHTML)
                    }
                }
                .labelsHidden()
                .fixedSize()
                Spacer()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(pathLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    FilterField(placeholder: pathPlaceholder, text: $path)
                    Button("Choose…") { chooseFile() }
                }
                Text(pathHint)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var pathLabel: String {
        switch source {
        case .chrome, .edge, .brave, .arc, .vivaldi, .opera, .chromium:
            return "\(source.displayName) bookmarks file"
        case .firefox:       return "Firefox places database"
        case .safari:        return "Safari bookmarks file"
        case .pocket:        return "Pocket HTML export"
        case .pinterest:     return "Pinterest data-download CSV"
        case .raindrop:      return "Raindrop.io CSV export"
        case .netscapeHTML:  return "Netscape-format HTML export"
        }
    }

    private var pathPlaceholder: String {
        switch source {
        case .chrome:        return "/Users/.../Google/Chrome/<Profile>/Bookmarks"
        case .edge:          return "/Users/.../Microsoft Edge/<Profile>/Bookmarks"
        case .brave:         return "/Users/.../BraveSoftware/Brave-Browser/<Profile>/Bookmarks"
        case .arc:           return "/Users/.../Arc/User Data/<Profile>/Bookmarks"
        case .vivaldi:       return "/Users/.../Vivaldi/<Profile>/Bookmarks"
        case .opera:         return "/Users/.../com.operasoftware.Opera/Bookmarks"
        case .chromium:      return "/Users/.../Chromium/<Profile>/Bookmarks"
        case .firefox:       return "/Users/.../Firefox/Profiles/<profile>/places.sqlite"
        case .safari:        return "/Users/.../Library/Safari/Bookmarks.plist"
        case .pocket:        return "Export from getpocket.com/export, then choose the file here"
        case .pinterest:     return "Extract Pinterest data-download .zip, then choose pins.csv"
        case .raindrop:      return "Settings → Backups → Export → CSV, then choose the .csv"
        case .netscapeHTML:  return "Export HTML from your browser, then choose it here"
        }
    }

    private var pathHint: String {
        switch source {
        case .chrome:
            return "Auto-detected from the active Chrome profile (Local State → profile.last_used). Chrome can be running."
        case .edge, .brave, .arc, .vivaldi, .chromium:
            return "Auto-detected from the browser's active profile. Same JSON format as Chrome — re-uses the Chrome parser. Browser can be running."
        case .opera:
            return "Opera stores a single bookmark file at its app-support root (no per-profile dir). Browser can be running."
        case .firefox:
            return "Auto-detected from profiles.ini → Default. Opened read-only — safe to import while Firefox is running."
        case .safari:
            return "Reading Safari bookmarks needs Full Disk Access. If discover fails with a permission error, grant access via System Settings → Privacy & Security → Full Disk Access (add /Users/<you>/.local/bin/stash), or export bookmarks via Safari → File → Export Bookmarks and use the HTML option."
        case .pocket:
            return "Pocket export at getpocket.com/export — produces a Netscape HTML file with `time_added` + tag metadata that the importer preserves."
        case .pinterest:
            return "Settings → Privacy and data → Request a copy of your data. Pinterest emails you a .zip; extract it and pick pins.csv. Boards become the tree hierarchy; descriptions become notes. Source URLs are preferred; image-only pins fall back to the image URL."
        case .raindrop:
            return "Settings → Backups → Export → CSV. The Raindrop folder column (with its `/`-separated nested-collection breadcrumb) drives the tree hierarchy, and Raindrop's native tags + folder names both flow into the per-item tag list."
        case .netscapeHTML:
            return "Chrome: chrome://bookmarks → ⋮ → Export bookmarks. Firefox: Library → Bookmarks → Show All Bookmarks → Import and Backup → Export Bookmarks to HTML."
        }
    }

    private func recomputePath() {
        switch source {
        case .chrome:        path = BookmarkSourceFinder.activeChromeBookmarks()?.path ?? ""
        case .edge:          path = BookmarkSourceFinder.activeEdgeBookmarks()?.path ?? ""
        case .brave:         path = BookmarkSourceFinder.activeBraveBookmarks()?.path ?? ""
        case .arc:           path = BookmarkSourceFinder.activeArcBookmarks()?.path ?? ""
        case .vivaldi:       path = BookmarkSourceFinder.activeVivaldiBookmarks()?.path ?? ""
        case .opera:         path = BookmarkSourceFinder.activeOperaBookmarks()?.path ?? ""
        case .chromium:      path = BookmarkSourceFinder.activeChromiumBookmarks()?.path ?? ""
        case .firefox:       path = BookmarkSourceFinder.defaultFirefoxPlaces()?.path ?? ""
        case .safari:        path = BookmarkSourceFinder.safariBookmarks()?.path ?? ""
        case .pocket:        path = ""
        case .pinterest:     path = ""
        case .raindrop:      path = ""
        case .netscapeHTML:  path = ""
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        switch source {
        case .chrome, .edge, .brave, .arc, .vivaldi, .opera, .chromium:
            panel.title = "Choose \(source.displayName) Bookmarks file"
            panel.allowedContentTypes = []   // Chromium bookmarks file has no extension
        case .firefox:
            panel.title = "Choose places.sqlite"
            panel.allowedContentTypes = [UTType(filenameExtension: "sqlite") ?? .data]
        case .safari:
            panel.title = "Choose Bookmarks.plist"
            panel.allowedContentTypes = [UTType(filenameExtension: "plist") ?? .data]
        case .pocket, .netscapeHTML:
            panel.title = "Choose Bookmarks HTML"
            panel.allowedContentTypes = [.html]
        case .pinterest, .raindrop:
            panel.title = "Choose \(source.displayName) CSV"
            panel.allowedContentTypes = [UTType(filenameExtension: "csv") ?? .commaSeparatedText]
        }
        if !path.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: path).deletingLastPathComponent()
        }
        if panel.runModal() == .OK, let url = panel.url {
            path = url.path
        }
    }

    // MARK: - Phase 3: review

    private var reviewPhase: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let preview, !preview.bookmarks.isEmpty {
                let dupCount = preview.bookmarks.filter { $0.alreadyInStash }.count
                HStack(spacing: 12) {
                    Text("\(preview.bookmarks.count) bookmark\(preview.bookmarks.count == 1 ? "" : "s") in \(preview.source)")
                        .font(.callout)
                    if dupCount > 0 {
                        Toggle("Hide \(dupCount) duplicate\(dupCount == 1 ? "" : "s")", isOn: $hideDuplicates)
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
                            treeRow(row.node, indent: row.indent)
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
                Text("No bookmarks found in this file.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Tree rendering

    /// Recursive tree node — folder or leaf. `id` is stable across
    /// re-renders so SwiftUI doesn't lose checkbox state mid-edit.
    indirect enum TreeNode: Identifiable {
        case folder(name: String, path: [String], children: [TreeNode])
        case leaf(StashCLI.BookmarkPreviewItem)

        var id: String {
            switch self {
            case .folder(_, let p, _): return "F/" + p.joined(separator: "›")
            case .leaf(let bm):        return "L/" + bm.url
            }
        }
    }

    private var tree: [TreeNode] {
        guard let preview else { return [] }
        let items = hideDuplicates
            ? preview.bookmarks.filter { !$0.alreadyInStash }
            : preview.bookmarks
        return buildTree(items: items, pathPrefix: [])
    }

    private func buildTree(items: [StashCLI.BookmarkPreviewItem], pathPrefix: [String]) -> [TreeNode] {
        // Items whose folderPath equals this prefix → direct leaves.
        let leaves = items.filter { $0.folderPath == pathPrefix }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        // Subfolder names = next segment after the prefix.
        var subfolderNames: [String] = []
        var seen = Set<String>()
        for item in items where item.folderPath.count > pathPrefix.count {
            let prefix = Array(item.folderPath.prefix(pathPrefix.count))
            guard prefix == pathPrefix else { continue }
            let name = item.folderPath[pathPrefix.count]
            if !seen.contains(name) {
                seen.insert(name)
                subfolderNames.append(name)
            }
        }
        subfolderNames.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        var nodes: [TreeNode] = []
        for name in subfolderNames {
            let nextPath = pathPrefix + [name]
            let childItems = items.filter { item in
                item.folderPath.count > pathPrefix.count
                && Array(item.folderPath.prefix(nextPath.count)) == nextPath
            }
            let children = buildTree(items: childItems, pathPrefix: nextPath)
            nodes.append(.folder(name: name, path: nextPath, children: children))
        }
        for leaf in leaves { nodes.append(.leaf(leaf)) }
        return nodes
    }

    /// A flattened tree row — node + how deep it is. Pre-walking the
    /// tree into this shape avoids the SwiftUI "recursive opaque
    /// return type" compile error you get from a function that
    /// renders itself recursively.
    struct FlatRow: Identifiable {
        let node: TreeNode
        let indent: Int
        var id: String { node.id }
    }

    private var flatRows: [FlatRow] {
        var out: [FlatRow] = []
        func walk(_ node: TreeNode, _ indent: Int) {
            out.append(FlatRow(node: node, indent: indent))
            if case .folder(_, _, let children) = node {
                for c in children { walk(c, indent + 1) }
            }
        }
        for n in tree { walk(n, 0) }
        return out
    }

    @ViewBuilder
    private func treeRow(_ node: TreeNode, indent: Int) -> some View {
        switch node {
        case .folder(let name, let path, _):
            HStack(spacing: 6) {
                folderCheckButton(path: path)
                Image(systemName: "folder.fill")
                    .foregroundStyle(.tint)
                Text(name)
                    .fontWeight(.semibold)
                Spacer()
                Text("\(folderURLs(path).count)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .padding(.leading, CGFloat(indent) * 18)
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
                            Text("DUPLICATE")
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
            .padding(.leading, CGFloat(indent) * 18)
        }
    }

    /// Tri-state folder checkbox. Off → click sets all descendants
    /// checked; mixed or all → click clears them. The icon-name
    /// computation lives in a helper so the `@ViewBuilder` body
    /// only contains View expressions (it doesn't accept plain
    /// `let icon = …` if/else assignments).
    private func folderCheckButton(path: [String]) -> some View {
        let urls = folderURLs(path)
        let checked = urls.filter { checkedURLs.contains($0) }.count
        let icon = folderCheckIcon(checked: checked, total: urls.count)
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

    private func folderCheckIcon(checked: Int, total: Int) -> String {
        if checked == 0 { return "square" }
        if checked == total { return "checkmark.square.fill" }
        return "minus.square.fill"
    }

    /// URLs in (or under) the given folder path — used by the folder
    /// checkbox to apply select-all / clear in one shot.
    private func folderURLs(_ path: [String]) -> [String] {
        guard let items = preview?.bookmarks else { return [] }
        return items.filter { bm in
            bm.folderPath.count >= path.count
            && Array(bm.folderPath.prefix(path.count)) == path
        }.map { $0.url }
    }

    private func urlBinding(_ url: String) -> Binding<Bool> {
        Binding(
            get: { checkedURLs.contains(url) },
            set: { newValue in
                if newValue { checkedURLs.insert(url) } else { checkedURLs.remove(url) }
            }
        )
    }

    /// Tag pills for one bookmark row. Each tag renders as a pill
    /// with an "×" to delete. The trailing "+" is a button by
    /// default; clicking it transforms into a focused FilterField
    /// for the row, and on Enter / Tab / click-away the typed
    /// value is committed and the row returns to the "+" affordance.
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

    /// Plus-icon button shown when the user is not actively adding
    /// a tag to this row. Click → flip `addingTagFor` to this row,
    /// which causes the field to render in its place with focus.
    private func addTagButton(for bm: StashCLI.BookmarkPreviewItem) -> some View {
        Button {
            // Clear any draft from a different row (only one field
            // can be active at a time) so a stale text doesn't
            // pre-fill the new one.
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

    /// The active tag-add field. Replaces the "+" while in use.
    /// Commits on Enter, Tab, or focus-loss; Escape cancels.
    private func addTagField(for bm: StashCLI.BookmarkPreviewItem) -> some View {
        let binding = Binding<String>(
            get: { newTagDrafts[bm.url] ?? "" },
            set: { value in
                // Comma also commits in-place — supports paste of
                // "tag1, tag2" without forcing the user to press
                // Enter twice.
                if value.contains(",") {
                    let parts = value
                        .split(separator: ",")
                        .map { normalizeTag(String($0)) }
                        .filter { !$0.isEmpty }
                    if !parts.isEmpty {
                        var current = currentTags(for: bm)
                        for p in parts where !current.contains(p) {
                            current.append(p)
                        }
                        editedTags[bm.url] = current
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
                // Click-away → commit whatever's typed and collapse
                // back to the "+" button. Only fires if this row
                // is still the active one (avoids a stale field's
                // onEndEditing tearing down a newly-opened one).
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
            Button {
                onRemove()
            } label: {
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
        let normalized = normalizeTag(draft)
        guard !normalized.isEmpty else {
            newTagDrafts[bm.url] = ""
            return
        }
        var current = currentTags(for: bm)
        if !current.contains(normalized) {
            current.append(normalized)
            editedTags[bm.url] = current
        }
        newTagDrafts[bm.url] = ""
    }

    /// Normalize a raw tag the same way the CLI's `normalizeTag`
    /// does: lowercase, trim whitespace, collapse internal runs of
    /// non-alphanumerics into a single hyphen. Keeps Mac-typed and
    /// folder-derived tags in the same shape.
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

    /// Tag pills for the "Extra tags applied to every picked item"
    /// area at the bottom of the review phase. Same gestures as
    /// per-row pills: click + to reveal field; Enter/Tab commit;
    /// Escape cancels; click-away commits.
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
                        case .tab:
                            commitSharedExtraDraft()
                            return true
                        case .escape:
                            sharedExtraDraft = ""
                            isAddingSharedExtra = false
                            return true
                        default:
                            return false
                        }
                    },
                    onEndEditing: {
                        if isAddingSharedExtra {
                            commitSharedExtraDraft()
                        }
                    }
                )
                .frame(width: 100)
            } else {
                Button {
                    isAddingSharedExtra = true
                } label: {
                    Image(systemName: "plus.circle")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                .buttonStyle(.plain)
                .help("Add tag applied to every picked item")
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

    /// Collection name with a typeable field plus a chevron menu
    /// of existing collections. Picking from the menu replaces the
    /// field; typing a new name creates that collection at apply
    /// time (CLI's `import apply` semantics).
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
            .help("Pick an existing collection or leave blank / type a new name")
        }
    }

    /// Error pane. Special-cases the Safari Full-Disk-Access
    /// error: instead of just dumping the long sentence, surface
    /// two action buttons so the user can resolve it in a few
    /// clicks rather than reading + manually navigating.
    @ViewBuilder
    private func errorBlock(_ message: String) -> some View {
        if isFDAError(message) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(.orange)
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Safari bookmarks need Full Disk Access")
                            .font(.callout)
                            .fontWeight(.medium)
                        Text("macOS blocks the `stash` CLI from reading Safari's bookmark store until you grant it Full Disk Access. Either grant access below, or export bookmarks from Safari ▸ File ▸ Export Bookmarks and use the HTML option.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(spacing: 8) {
                    Button("Open System Settings…") { openFullDiskAccessSettings() }
                    Button("Reveal stash CLI in Finder") { revealStashBinary() }
                    Spacer()
                }
                .controlSize(.small)
            }
            .padding(10)
            .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.orange.opacity(0.35), lineWidth: 1)
            )
        } else {
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func isFDAError(_ message: String) -> Bool {
        message.contains("Full Disk Access")
    }

    /// Open System Settings deep-linked to the Full Disk Access
    /// pane. The URL scheme works on macOS 13+; older versions
    /// fall back to the top-level Privacy pane on their own.
    private func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Reveal the `stash` CLI binary in Finder so the user can drag
    /// it into the Full Disk Access list. Walks the same candidate
    /// paths the Mac app uses for resolution.
    private func revealStashBinary() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/stash",
            "\(home)/go/bin/stash",
            "/usr/local/bin/stash",
            "/opt/homebrew/bin/stash",
        ]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: found)])
        } else {
            // Fall back to ~/.local/bin if nothing's resolvable, so
            // at least the dir opens.
            NSWorkspace.shared.open(URL(fileURLWithPath: "\(home)/.local/bin"))
        }
    }

    private func selectAll() {
        guard let items = preview?.bookmarks else { return }
        // Skip already-imported items — the user has explicitly
        // asked to default-uncheck duplicates, and the apply step
        // dedups anyway. Select-all-including-dupes can be done
        // manually by clicking each row.
        checkedURLs = Set(items.filter { !$0.alreadyInStash }.map { $0.url })
    }

    // MARK: - Phase 4/5: importing/done

    private func loadingBlock(_ msg: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(msg).font(.callout)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    @ViewBuilder
    private var donePhase: some View {
        if let s = lastSummary {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(doneSummaryText(s))
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
                Text("Re-importing this same file later will skip what's already in (dedup by URL).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func doneSummaryText(_ s: StashCLI.ImportSummary) -> String {
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
                    .disabled(path.trimmingCharacters(in: .whitespaces).isEmpty)
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

    // MARK: - Actions

    private func runDiscover() {
        let trimmedPath = path.trimmingCharacters(in: .whitespaces)
        guard !trimmedPath.isEmpty else { return }
        error = nil
        phase = .discovering
        Task {
            do {
                let p = try await StashCLI.shared.previewBookmarks(source: source, path: trimmedPath)
                await MainActor.run {
                    preview = p
                    // Default: nothing pre-checked. Users overwhelmingly
                    // want to pick a subset; a full pre-check defeats
                    // the purpose of the review step.
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
        // Flush any in-progress "add a tag" drafts so a tag the
        // user typed but didn't press Enter on still gets included.
        for url in Array(newTagDrafts.keys) {
            if let bm = preview?.bookmarks.first(where: { $0.url == url }) {
                commitNewTag(bm)
            }
        }

        // Flush the shared-extras draft too.
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
                    // Uncheck the just-imported URLs so "Import More"
                    // returns to a clean slate.
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
