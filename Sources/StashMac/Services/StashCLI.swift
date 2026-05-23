import Foundation

actor StashCLI {
    static let shared = StashCLI()

    private var binaryPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/stash",
            "\(home)/go/bin/stash",
            "/usr/local/bin/stash",
            "/opt/homebrew/bin/stash",
            "\(home)/workspace/go/gostash/stash",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            ?? "stash"
    }

    private var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// Encoder for outbound JSON (e.g. piping a rule into `stash autotag save`).
    /// Mirrors the decoder's snake_case convention so the CLI sees field names
    /// matching its Go struct tags.
    private var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }

    // MARK: - Items

    func listItems(
        type: ItemType? = nil,
        tags: [String] = [],
        excludeTags: [String] = [],
        collection: String? = nil,
        limit: Int = 50
    ) async throws -> [StashItem] {
        var args = ["list", "--json", "-l", "\(limit)"]
        if let type { args += ["--type", type.rawValue] }
        for tag in tags { args += ["--tag", tag] }
        for tag in excludeTags { args += ["--exclude-tag", tag] }
        if let collection { args += ["--collection", collection] }
        return try await captureJSON(args: args)
    }

    func searchItems(
        query: String,
        type: ItemType? = nil,
        tags: [String] = [],
        excludeTags: [String] = [],
        collection: String? = nil,
        limit: Int = 50,
        regex: String? = nil
    ) async throws -> [StashItem] {
        // The query goes after `--` so cobra stops walking subcommands —
        // otherwise queries like "delete", "save", "list", or "run"
        // resolve to `stash search delete` etc. and the trailing `-l`
        // becomes an unknown flag.
        //
        // Regex mode passes the pattern via `--regex` and skips the
        // positional query; free-text mode passes the positional query
        // (FTS-backed). Tag filters work in both modes.
        var args = ["search", "--json", "-l", "\(limit)"]
        if let type { args += ["--type", type.rawValue] }
        for tag in tags { args += ["--tag", tag] }
        for tag in excludeTags { args += ["--exclude-tag", tag] }
        if let collection, !collection.isEmpty {
            args += ["--collection", collection]
        }
        if let regex, !regex.isEmpty {
            args += ["--regex", regex]
        }
        if regex == nil || regex!.isEmpty {
            args += ["--", query]
        }
        return try await captureJSON(args: args)
    }

    func getItem(id: String) async throws -> StashItem {
        try await captureJSON(args: ["show", "--json", id])
    }

    func addURL(
        url: String,
        title: String? = nil,
        tags: [String] = [],
        note: String? = nil,
        collection: String? = nil
    ) async throws -> StashItem {
        var args = ["add", "--json", url]
        if let title { args += ["-t", title] }
        for tag in tags { args += ["-T", tag] }
        if let note { args += ["-n", note] }
        if let collection { args += ["-c", collection] }
        return try await captureJSON(args: args)
    }

    func addFile(
        path: String,
        title: String? = nil,
        tags: [String] = [],
        note: String? = nil,
        collection: String? = nil
    ) async throws -> StashItem {
        var args = ["add", "--json", path]
        if let title { args += ["-t", title] }
        for tag in tags { args += ["-T", tag] }
        if let note { args += ["-n", note] }
        if let collection { args += ["-c", collection] }
        return try await captureJSON(args: args)
    }

    func addSnippet(
        text: String,
        title: String? = nil,
        tags: [String] = [],
        note: String? = nil,
        collection: String? = nil
    ) async throws -> StashItem {
        var args = ["add", "--json", "-"]
        if let title { args += ["-t", title] }
        for tag in tags { args += ["-T", tag] }
        if let note { args += ["-n", note] }
        if let collection { args += ["-c", collection] }
        return try await captureJSONWithStdin(args: args, input: text)
    }

    func editItem(
        id: String,
        title: String? = nil,
        note: String? = nil,
        extractedText: String? = nil,
        url: String? = nil,
        addTags: [String] = [],
        removeTags: [String] = [],
        collection: String? = nil,
        location: ItemLocation? = nil,
        clearLocation: Bool = false
    ) async throws -> StashItem {
        var args = ["edit", "--json", id]
        if let title { args += ["-t", title] }
        if let note { args += ["-n", note] }
        if let extractedText { args += ["-e", extractedText] }
        if let url { args += ["-u", url] }
        for tag in addTags { args += ["--add-tag", tag] }
        for tag in removeTags { args += ["--remove-tag", tag] }
        if let collection { args += ["-c", collection] }
        if let location {
            args += ["--location", "\(location.lat),\(location.lon)"]
        } else if clearLocation {
            args += ["--clear-location"]
        }
        return try await captureJSON(args: args)
    }

    /// Copy a single field of an item to the clipboard via the
    /// `stash copy` subcommand. Used by the Health Check row context
    /// menu so the Mac doesn't need to re-implement the platform-
    /// specific clipboard pipe.
    func copyItemField(id: String, field: String) async throws {
        _ = try await captureOutput(args: ["copy", id, "--field", field])
    }

    /// Drive `stash heal <id>` to re-fetch a missing content blob
    /// from the item's source URL. Used by the detail-pane
    /// MissingBlobBanner. Returns void on success; throws with the
    /// CLI's stderr on failure.
    func healItem(id: String) async throws {
        _ = try await captureOutput(args: ["heal", id])
    }

    /// Pairing payload from `stash serve pair --json`. Used by the
    /// Settings → Phone pairing tab to render a QR locally for the
    /// Android app.
    struct PairInfo: Codable {
        let host: String
        let port: Int
        let token: String
        let uri: String
    }

    /// Drive `stash serve pair --json` to get the pairing URI for
    /// the currently-running daemon. Doesn't restart the daemon.
    func pairInfo() async throws -> PairInfo {
        try await captureJSON(args: ["serve", "pair", "--json"])
    }

    /// Rotate the bearer token via `stash serve token --rotate`.
    /// Invalidates every paired device — they'll all need to
    /// re-scan the new QR.
    func rotateServeToken() async throws {
        _ = try await captureOutput(args: ["serve", "token", "--rotate"])
    }

    // MARK: - Trip / event suggestions

    /// One row returned by `stash moments --json`. The CLI side
    /// is the source of truth for the clustering algorithm; this
    /// struct mirrors the JSON shape so the Mac UI can render
    /// suggestions without re-implementing the heuristic.
    struct MomentSuggestion: Codable, Identifiable, Equatable {
        let start: Date
        let end: Date
        let itemCount: Int
        let items: [MomentItem]
        let suggestedName: String
        let score: Double
        let sharedTags: [String]?
        let locationCenter: LocationCenter?
        let locationCount: Int?
        /// SHA-256 of the cluster's sorted item-ID set. Used as the
        /// argument to `stash moments undismiss <sig>` if the user
        /// wants to un-hide a previously-dismissed cluster. Adding
        /// or removing items from the cluster produces a different
        /// signature, so a dismissal only hides the EXACT cluster
        /// the user rejected.
        let signature: String

        struct LocationCenter: Codable, Equatable {
            let lat: Double
            let lon: Double
        }

        /// Per-item preview: enough metadata to render a filmstrip
        /// and let the user verify what they're about to bundle
        /// without a second round trip per item. `storePath` is the
        /// content-hashed blob path used as a fallback when no
        /// thumbnail has been generated yet (image items pre-dating
        /// thumbnail-backfill render fine from the original blob at
        /// small tile sizes).
        struct MomentItem: Codable, Equatable, Hashable {
            let id: String
            let title: String?
            let type: String?
            let thumbnailPath: String?
            let storePath: String?
        }

        /// Convenience for the accept path — just the ID list.
        var itemIds: [String] { items.map(\.id) }

        // Synthesize a stable identity from the first item ID + score
        // so SwiftUI lists don't re-shuffle on every refresh.
        var id: String { (items.first?.id ?? "?") + "|" + String(score) }
    }

    /// Drive `stash moments --json`. Default flags match the CLI
    /// defaults (90-day window, 6h gap, 5-day span, min-items 3).
    /// Returns a score-sorted slice for direct rendering.
    func momentSuggestions(scanAll: Bool = false) async throws -> [MomentSuggestion] {
        var args = ["moments", "--json"]
        if scanAll { args.append("--all") }
        return try await captureJSON(args: args)
    }

    /// Action a suggestion by creating (or reusing) a collection and
    /// adding the listed items. Idempotent on the CLI side.
    func acceptMoment(name: String, ids: [String], description: String? = nil) async throws {
        var args = ["moments", "accept", "--name", name]
        if let description, !description.isEmpty {
            args += ["--description", description]
        }
        args.append(contentsOf: ids)
        _ = try await captureOutput(args: args)
    }

    /// Mark a cluster as user-rejected so it stops appearing in
    /// future `stash moments` runs. The CLI rebuilds the signature
    /// from the item IDs we pass; we send the full ID list so the
    /// Mac doesn't have to share the hashing implementation. Note
    /// that the cluster's signature changes if its items change —
    /// dismissing X+Y+Z doesn't hide X+Y or X+Y+W.
    func dismissMoment(itemIDs: [String]) async throws {
        var args = ["moments", "dismiss"]
        args.append(contentsOf: itemIDs)
        _ = try await captureOutput(args: args)
    }

    /// Re-surface a previously-dismissed cluster by its signature.
    func undismissMoment(signature: String) async throws {
        _ = try await captureOutput(args: ["moments", "undismiss", signature])
    }

    // MARK: - Multi-file items (attach / detach / reorder / merge)

    /// Attach a local file as an additional photo on an existing
    /// item. Drives `stash attach`. Returns the refreshed item with
    /// the new ItemFile included in its `files` array.
    func attachFile(itemID: String, path: String, caption: String? = nil) async throws -> StashItem {
        var args = ["attach", itemID, path]
        if let caption, !caption.isEmpty {
            args += ["--caption", caption]
        }
        _ = try await captureOutput(args: args)
        return try await captureJSON(args: ["show", itemID, "--json"])
    }

    /// Detach an attached file. `index` is 1-based — `0` is the
    /// primary and can't be detached (use `promoteFile` first).
    func detachFile(itemID: String, index: Int) async throws -> StashItem {
        _ = try await captureOutput(args: ["detach", itemID, "\(index)"])
        return try await captureJSON(args: ["show", itemID, "--json"])
    }

    /// Promote an attached file to be the new primary. The previous
    /// primary becomes attachment position 0 — nothing is lost.
    func promoteFile(itemID: String, index: Int) async throws -> StashItem {
        _ = try await captureOutput(args: ["primary", itemID, "\(index)"])
        return try await captureJSON(args: ["show", itemID, "--json"])
    }

    /// Reorder the carousel. `attachmentIndices` is the new order
    /// of attached-file slots (1-based, primary excluded).
    func reorderFiles(itemID: String, attachmentIndices: [Int]) async throws -> StashItem {
        var args = ["reorder", itemID]
        for i in attachmentIndices { args.append("\(i)") }
        _ = try await captureOutput(args: args)
        return try await captureJSON(args: ["show", itemID, "--json"])
    }

    /// Merge one or more source items into a target. Source primaries
    /// become attached files of target, tags union, notes append
    /// below "---", sources are deleted. Returns the merged target.
    func mergeItems(targetID: String, sourceIDs: [String]) async throws -> StashItem {
        var args = ["merge", targetID]
        args.append(contentsOf: sourceIDs)
        _ = try await captureOutput(args: args)
        return try await captureJSON(args: ["show", targetID, "--json"])
    }

    /// Run a focused URL recheck on a single item via
    /// `stash check --urls --id <id> --json`. Returns true if the
    /// URL is still broken, false if it now responds OK. Used by
    /// stash-mac's Health Check view to verify after a URL edit
    /// without re-fetching every URL in the library.
    /// Returns the matching CheckIssue if the URL is still broken
    /// after re-probing, or nil if it now responds healthily.
    /// Result of `stash export --json`. Mirrors `archive.ExportResult`.
    struct ExportResult: Codable {
        let path: String
        let itemCount: Int
        let blobCount: Int
        let totalBytes: Int64
    }

    /// Selection criteria for an export. Exactly one case wins.
    enum ExportScope {
        case ids([String])
        case tag(String)
        case collection(String)
        case all
    }

    /// Wrap `stash export` — bundles the requested items into a zip
    /// archive at `outPath`. Long ID lists are piped via stdin so we
    /// never blow argv limits on large multi-selects.
    func exportItems(
        scope: ExportScope,
        outPath: String,
        includeArchived: Bool = false
    ) async throws -> ExportResult {
        var args = ["export", "--json", "--out", outPath]
        if includeArchived { args.append("--include-archived") }
        switch scope {
        case .ids(let ids):
            args += ["-"]  // ids on stdin, one per line
            return try await captureJSONWithStdin(args: args, input: ids.joined(separator: "\n"))
        case .tag(let name):
            args += ["--tag", name]
        case .collection(let name):
            args += ["--collection", name]
        case .all:
            args.append("--all")
        }
        return try await captureJSON(args: args)
    }

    /// Result of `stash import archive --json`. Mirrors
    /// `archive.ImportSummary`. Two CLI paths emit this shape:
    /// `import archive` (with full conflict policy → fills `replaced`
    /// and `reassigned`) and `import apply` (manifest-driven → only
    /// imports/skips, the other counters are absent). Decode is
    /// defensive so a missing `replaced`/`reassigned` from `import
    /// apply` doesn't trip "data is missing".
    struct ImportSummary: Codable {
        let imported: Int
        let skipped: Int
        let replaced: Int
        let reassigned: Int
        let errors: [String]?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            imported = try c.decodeIfPresent(Int.self, forKey: .imported) ?? 0
            skipped = try c.decodeIfPresent(Int.self, forKey: .skipped) ?? 0
            replaced = try c.decodeIfPresent(Int.self, forKey: .replaced) ?? 0
            reassigned = try c.decodeIfPresent(Int.self, forKey: .reassigned) ?? 0
            errors = try c.decodeIfPresent([String].self, forKey: .errors)
        }

        enum CodingKeys: String, CodingKey {
            case imported, skipped, replaced, reassigned, errors
        }
    }

    /// Conflict policy for imports. Mirrors `archive.ConflictPolicy`.
    enum ImportPolicy: String { case newID = "new-id", skip, replace }

    /// Result of `stash import {chrome|firefox|bookmarks} --json`.
    struct BookmarkImportSummary: Codable {
        let imported: Int
        let skipped: Int
        let total: Int
        let path: String?
        let source: String?
    }

    /// Bookmark source for `importBookmarks(...)`. Each source maps
    /// to a `stash import <subcommand>`; multiple sources can map
    /// to the same subcommand when the file format is shared (the
    /// Chromium-family browsers all use the same JSON, so they all
    /// route to `import chrome`).
    ///
    /// - `.chrome / .edge / .brave / .arc / .vivaldi / .opera /
    ///   .chromium` → `import chrome` (Chromium JSON format).
    /// - `.firefox` → `import firefox` (places.sqlite read-only).
    /// - `.safari`  → `import safari` (binary plist; needs FDA).
    /// - `.pocket`  → `import pocket` (Pocket HTML export).
    /// - `.netscapeHTML` → `import bookmarks` (generic HTML export).
    enum BookmarkSource: String, CaseIterable, Identifiable {
        case chrome, edge, brave, arc, vivaldi, opera, chromium
        case firefox
        case safari
        case pocket
        case pinterest
        case raindrop
        case netscapeHTML

        var id: String { rawValue }

        /// CLI subcommand under `stash import` that handles this
        /// source. Chromium-family all share `chrome` since the
        /// on-disk format is identical.
        var cliSubcommand: String {
            switch self {
            case .chrome, .edge, .brave, .arc, .vivaldi, .opera, .chromium:
                return "chrome"
            case .firefox:       return "firefox"
            case .safari:        return "safari"
            case .pocket:        return "pocket"
            case .pinterest:     return "pinterest"
            case .raindrop:      return "raindrop"
            case .netscapeHTML:  return "bookmarks"
            }
        }

        /// Display name in the Mac importer's source picker.
        var displayName: String {
            switch self {
            case .chrome:        return "Chrome"
            case .edge:          return "Edge"
            case .brave:         return "Brave"
            case .arc:           return "Arc"
            case .vivaldi:       return "Vivaldi"
            case .opera:         return "Opera"
            case .chromium:      return "Chromium"
            case .firefox:       return "Firefox"
            case .safari:        return "Safari"
            case .pocket:        return "Pocket"
            case .pinterest:     return "Pinterest"
            case .raindrop:      return "Raindrop.io"
            case .netscapeHTML:  return "HTML export"
            }
        }
    }

    // MARK: - Bookmark preview + apply (multi-phase importer)

    /// One bookmark discovered by `import <source> --dry-run --json`.
    /// Carries enough context for the Mac importer's tree UI to
    /// render the original folder hierarchy and let the user edit
    /// tags before committing.
    ///
    /// Decoding is defensive: every optional list / string defaults
    /// to an empty value if the JSON key is null or missing. The
    /// Go side emits both shapes for nil slices depending on
    /// version — older builds emitted `null`, newer ones emit `[]`
    /// — and we shouldn't fail import discovery on either.
    struct BookmarkPreviewItem: Codable, Hashable, Identifiable {
        let url: String
        let title: String
        let folderPath: [String]
        let defaultTags: [String]
        let createdAt: String?
        let notes: String?
        /// CLI dry-run sets this to true when the URL is already in
        /// the stash — the Mac importer uses it to default-uncheck
        /// the row and prepend a "DUPLICATE" badge so the user can
        /// review and re-pick if they want to overwrite (a future
        /// `--policy replace` would honor the pick).
        let alreadyInStash: Bool

        var id: String { url }

        enum CodingKeys: String, CodingKey {
            case url, title
            case folderPath = "folder_path"
            case defaultTags = "default_tags"
            case createdAt = "created_at"
            case notes
            case alreadyInStash = "already_in_stash"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            url = try c.decode(String.self, forKey: .url)
            title = try c.decodeIfPresent(String.self, forKey: .title) ?? url
            folderPath = try c.decodeIfPresent([String].self, forKey: .folderPath) ?? []
            defaultTags = try c.decodeIfPresent([String].self, forKey: .defaultTags) ?? []
            createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
            notes = try c.decodeIfPresent(String.self, forKey: .notes)
            alreadyInStash = try c.decodeIfPresent(Bool.self, forKey: .alreadyInStash) ?? false
        }
    }

    /// Result of a preview discovery — the full bookmark set the CLI
    /// would import, plus the source label + path it was read from.
    /// Same defensive decode as the item type: a missing or null
    /// `bookmarks` array decodes as empty rather than failing.
    struct BookmarkPreview: Codable {
        let source: String
        let path: String
        let bookmarks: [BookmarkPreviewItem]

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
            path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
            bookmarks = try c.decodeIfPresent([BookmarkPreviewItem].self, forKey: .bookmarks) ?? []
        }

        enum CodingKeys: String, CodingKey {
            case source, path, bookmarks
        }
    }

    /// One item the user has approved for import. Tags here are the
    /// final list (possibly edited from `default_tags`).
    struct BookmarkApplyItem: Codable {
        let url: String
        let title: String
        let tags: [String]?
        let createdAt: String?
        let notes: String?

        enum CodingKeys: String, CodingKey {
            case url, title, tags, notes
            case createdAt = "created_at"
        }
    }

    /// Manifest piped to `import apply --json` on stdin.
    struct BookmarkApplyManifest: Codable {
        let collection: String?
        let items: [BookmarkApplyItem]
    }

    /// Run `stash import <source> --dry-run --json <path>` and decode
    /// the result. Paired with `applyBookmarkManifest` for the
    /// preview → curated-commit flow.
    ///
    /// Uses a dedicated decoder with **no** key strategy because the
    /// preview structs use explicit `CodingKeys` to map the
    /// snake_case JSON keys. The shared `decoder` property has
    /// `.convertFromSnakeCase` set, which has interacted oddly with
    /// explicit CodingKeys in past sessions — the safe route is to
    /// take the strategy out of the picture entirely for this path.
    func previewBookmarks(source: BookmarkSource, path: String) async throws -> BookmarkPreview {
        let output = try await captureOutput(args: ["import", source.cliSubcommand, "--dry-run", "--json", path])
        guard let data = output.data(using: .utf8) else {
            throw CLIError.failed("Invalid UTF-8 output from import preview")
        }
        let plainDecoder = JSONDecoder()
        return try plainDecoder.decode(BookmarkPreview.self, from: data)
    }

    // MARK: - URL exclusions (config.toml)

    /// One configured URL-redact rule. The CLI's `stash config
    /// exclusions ...` subcommands round-trip this shape exactly.
    struct URLExclusion: Codable, Hashable, Identifiable {
        let pattern: String
        let match: String       // "domain" | "regex"
        let behavior: String    // "domain" | "clear"

        var id: String { pattern }

        init(pattern: String, match: String = "domain", behavior: String = "domain") {
            self.pattern = pattern
            self.match = match
            self.behavior = behavior
        }
    }

    /// Read the configured exclusion rules. Empty array when none
    /// are set (or when config.toml doesn't exist yet — the CLI
    /// emits `{"exclusions": null}` in that case which decodes to
    /// nil → []).
    func listURLExclusions() async throws -> [URLExclusion] {
        struct Wire: Codable {
            let exclusions: [URLExclusion]?
        }
        let w: Wire = try await captureJSON(args: ["config", "exclusions", "list", "--json"])
        return w.exclusions ?? []
    }

    /// Add or update a rule. Idempotent — re-adding the same
    /// pattern replaces the rule's match / behavior in place.
    func addURLExclusion(_ rule: URLExclusion) async throws {
        _ = try await captureOutput(args: [
            "config", "exclusions", "add", rule.pattern,
            "--match", rule.match,
            "--behavior", rule.behavior,
            "--json",
        ])
    }

    func removeURLExclusion(pattern: String) async throws {
        _ = try await captureOutput(args: [
            "config", "exclusions", "remove", pattern, "--json",
        ])
    }

    /// Browser sources for `import history`. Mirrors `BookmarkSource`
    /// but only includes the variants that have a local history DB
    /// — Pocket / Pinterest / Raindrop / generic-HTML aren't browsers.
    enum HistoryBrowser: String, CaseIterable, Identifiable {
        case chrome, edge, brave, arc, vivaldi, opera, chromium
        case firefox
        case safari

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .chrome: return "Chrome"
            case .edge: return "Edge"
            case .brave: return "Brave"
            case .arc: return "Arc"
            case .vivaldi: return "Vivaldi"
            case .opera: return "Opera"
            case .chromium: return "Chromium"
            case .firefox: return "Firefox"
            case .safari: return "Safari"
            }
        }
    }

    /// Run `stash import history <browser> --since N --dry-run --json`
    /// and decode the result. Reuses `BookmarkPreview` since the row
    /// shape (url / title / created_at / already_in_stash) is
    /// identical — the importer just leaves `folder_path` empty
    /// and uses `created_at` for last-visited.
    func previewBrowserHistory(browser: HistoryBrowser, sinceDays: Int) async throws -> BookmarkPreview {
        let output = try await captureOutput(args: [
            "import", "history", browser.rawValue,
            "--since", String(sinceDays),
            "--dry-run", "--json",
        ])
        guard let data = output.data(using: .utf8) else {
            throw CLIError.failed("Invalid UTF-8 output from import history")
        }
        return try JSONDecoder().decode(BookmarkPreview.self, from: data)
    }

    /// Pipe a manifest of curated items into `stash import apply --json`.
    /// Same dedup-by-URL semantics as the single-shot importBookmarks
    /// path; the difference is the user's hand-picked subset + edited
    /// per-item tags rather than the full file.
    func applyBookmarkManifest(_ manifest: BookmarkApplyManifest) async throws -> ImportSummary {
        let data = try JSONEncoder().encode(manifest)
        guard let json = String(data: data, encoding: .utf8) else {
            throw CLIError.failed("encode manifest: invalid UTF-8")
        }
        return try await captureJSONWithStdin(
            args: ["import", "apply", "--json"],
            input: json
        )
    }

    func importBookmarks(
        source: BookmarkSource,
        path: String,
        extraTags: [String] = [],
        collection: String? = nil
    ) async throws -> BookmarkImportSummary {
        var args = ["import", source.cliSubcommand, "--json", path]
        for tag in extraTags { args += ["--tag", tag] }
        if let collection, !collection.isEmpty { args += ["--collection", collection] }
        return try await captureJSON(args: args)
    }

    // MARK: - Fetch URL (image/file discovery picker)

    /// One downloadable resource discovered on a page. Mirrors
    /// `pageCandidate` in `cmd/stash/fetch_url.go`.
    struct FetchURLCandidate: Codable, Identifiable, Hashable {
        let url: String
        let label: String
        let mime: String?
        let size: Int64?
        let kind: String   // "image" | "link"

        var id: String { url }
    }

    /// Result of `stash fetch-url --list <url> --json`. Either a page
    /// scrape with multiple candidates or a single-file direct
    /// download. Decoded via the shared "type" tag.
    enum FetchURLDiscovery {
        case page(pageURL: String, title: String?, candidates: [FetchURLCandidate])
        case direct(url: String, title: String?, mime: String, size: Int64)
    }

    /// One stashed item produced by a `--pick` call. Mirrors
    /// `pickedItem` in `cmd/stash/fetch_url.go`.
    struct FetchURLPickedItem: Codable, Identifiable {
        let id: String
        let url: String
        let title: String
        let type: String
    }

    /// Result of `stash fetch-url --pick … --json`.
    struct FetchURLPickResult: Codable {
        let imported: [FetchURLPickedItem]
        let linkedTo: String?
        let errors: [String]?

        enum CodingKeys: String, CodingKey {
            case imported
            case linkedTo = "linked_to"
            case errors
        }
    }

    /// Run `stash fetch-url --list <url> --json` and decode the
    /// discriminated result. `allLinks` widens the picker to include
    /// hyperlinks (not just images), mirroring the Chrome extension's
    /// "include all links" toggle.
    func fetchURLDiscover(url: String, allLinks: Bool = false) async throws -> FetchURLDiscovery {
        var args = ["fetch-url", "--list", "--json", url]
        if allLinks { args.append("--all-links") }
        let output = try await captureOutput(args: args)
        guard let raw = output.data(using: .utf8) else {
            throw CLIError.failed("Invalid UTF-8 output from fetch-url")
        }
        struct TaggedPeek: Codable { let type: String }
        let peek = try JSONDecoder().decode(TaggedPeek.self, from: raw)
        switch peek.type {
        case "page":
            // The CLI emits `"candidates": null` (not `[]`) when no
            // images / links are discovered — decode as optional and
            // default to an empty array so 0-candidate pages render
            // as "0 candidates found" rather than a decode error.
            struct PageWire: Codable {
                let pageURL: String
                let pageTitle: String?
                let candidates: [FetchURLCandidate]?
                enum CodingKeys: String, CodingKey {
                    case pageURL = "page_url"
                    case pageTitle = "page_title"
                    case candidates
                }
            }
            let p = try JSONDecoder().decode(PageWire.self, from: raw)
            return .page(pageURL: p.pageURL, title: p.pageTitle, candidates: p.candidates ?? [])
        case "direct":
            struct DirectWire: Codable {
                let url: String
                let title: String?
                let mime: String
                let size: Int64
            }
            let d = try JSONDecoder().decode(DirectWire.self, from: raw)
            return .direct(url: d.url, title: d.title, mime: d.mime, size: d.size)
        default:
            throw NSError(
                domain: "StashCLI",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Unknown fetch-url result type: \(peek.type)"]
            )
        }
    }

    /// Run `stash fetch-url --pick <picks…> --json <pageURL>`. Each
    /// pick URL becomes its own item; `linkSource = true` cross-links
    /// every picked item with the source page's URL item, mirroring
    /// the "stash link items together" intent for batch captures.
    func fetchURLPick(
        pageURL: String,
        picks: [String],
        linkSource: Bool = false,
        clique: Bool = false,
        archive: Bool = false,
        tags: [String] = [],
        collection: String? = nil
    ) async throws -> FetchURLPickResult {
        var args = ["fetch-url", "--json"]
        for p in picks { args += ["--pick", p] }
        // `--link-source` is a String flag (URL or item id) on the
        // CLI; passing the page URL as its value points the spokes at
        // a source item that's auto-created if missing.
        if linkSource { args += ["--link-source", pageURL] }
        if clique { args.append("--clique") }
        if archive { args.append("--archive") }
        for tag in tags { args += ["--tag", tag] }
        if let collection, !collection.isEmpty { args += ["--collection", collection] }
        args.append(pageURL)
        return try await captureJSON(args: args)
    }

    /// Wrap `stash import archive` — read items out of a zip
    /// produced by `exportItems` and add them to the local stash.
    func importArchive(
        path: String,
        policy: ImportPolicy = .newID,
        stripTags: Bool = false,
        stripCollections: Bool = false,
        stripArchived: Bool = false
    ) async throws -> ImportSummary {
        var args = ["import", "archive", "--json", "--policy", policy.rawValue, path]
        if stripTags { args.append("--strip-tags") }
        if stripCollections { args.append("--strip-collections") }
        if stripArchived { args.append("--strip-archived") }
        return try await captureJSON(args: args)
    }

    /// Read recent tag-mutation events from $STASH_DIR/tags.log via
    /// `stash tag-log --json -l <limit>`. Newest-first. Pass `limit = 0`
    /// to read everything currently in the file.
    func recentTagEvents(limit: Int = 100) async throws -> [TagEvent] {
        var args = ["tag-log", "--json"]
        if limit > 0 { args += ["-l", String(limit)] }
        return try await captureJSON(args: args)
    }

    func recheckURL(id: String) async throws -> CheckIssue? {
        let result: CheckResult = try await captureJSON(
            args: ["check", "--urls", "--id", id, "--json"]
        )
        return result.brokenUrls?.first(where: { $0.id == id })
    }

    func deleteItem(id: String) async throws {
        _ = try await captureOutput(args: ["delete", "--json", "-y", id])
    }

    // MARK: - Thumbnails

    /// Set the per-item thumbnail from a local file. Caller is
    /// responsible for post-processing (saliency crop, sRGB, JPEG
    /// encode) — the CLI just copies the file into the filestore.
    /// Returns the relative path stored on the item.
    @discardableResult
    func thumbnailSet(id: String, file: String) async throws -> String {
        struct Resp: Decodable { let thumbnailPath: String }
        let r: Resp = try await captureJSON(
            args: ["thumbnail", "set", id, "--file", file, "--json"]
        )
        return r.thumbnailPath
    }

    /// Set the per-item thumbnail from a remote image URL. CLI
    /// downloads, writes to the filestore, updates the column.
    @discardableResult
    func thumbnailSet(id: String, url: String) async throws -> String {
        struct Resp: Decodable { let thumbnailPath: String }
        let r: Resp = try await captureJSON(
            args: ["thumbnail", "set", id, "--url", url, "--json"]
        )
        return r.thumbnailPath
    }

    /// Remove the per-item thumbnail (file + column).
    func thumbnailClear(id: String) async throws {
        _ = try await captureOutput(args: ["thumbnail", "clear", id, "--json"])
    }

    /// Import a thumbnail by fetching a URL — defaults to the item's
    /// own URL when `from` is nil. Server-side decides whether to
    /// scrape (HTML) or use directly (image/*). Returns the relative
    /// path stored on the item plus optional sourcing metadata.
    struct ThumbnailImportResult: Decodable {
        let id: String
        let thumbnailPath: String
        let source: String?
        let candidateUrl: String?
    }

    @discardableResult
    func thumbnailImport(id: String, from: String? = nil) async throws -> ThumbnailImportResult {
        var args = ["thumbnail", "import", id, "--json"]
        if let from, !from.isEmpty { args += ["--from", from] }
        return try await captureJSON(args: args)
    }

    /// Run the import in candidates-only mode — returns the ranked
    /// candidate list without persisting, for the picker sheet.
    struct ThumbnailCandidate: Decodable, Identifiable, Hashable {
        let url: String
        let source: String
        let width: Int?
        let height: Int?
        let score: Int

        var id: String { url }
    }

    func thumbnailCandidates(id: String, from: String? = nil) async throws -> [ThumbnailCandidate] {
        var args = ["thumbnail", "import", id, "--candidates", "--json"]
        if let from, !from.isEmpty { args += ["--from", from] }
        return try await captureJSON(args: args)
    }

    func openItem(id: String) async throws {
        _ = try await captureOutput(args: ["open", id])
    }

    // MARK: - Links

    func linkItems(from: String, to: String, label: String? = nil, directed: Bool = false) async throws {
        var args = ["link", "--json", from, to]
        if let label, !label.isEmpty { args += ["-l", label] }
        if directed { args += ["--directed"] }
        _ = try await captureOutput(args: args)
    }

    func unlinkItems(idA: String, idB: String) async throws {
        _ = try await captureOutput(args: ["unlink", "--json", idA, idB])
    }

    // MARK: - Tags

    func listTags() async throws -> [StashTag] {
        try await captureJSON(args: ["tag", "list", "--json"])
    }

    func refreshItem(id: String) async throws -> StashItem {
        try await captureJSON(args: ["refresh", "--json", id])
    }

    func tagGraph() async throws -> TagGraphData {
        try await captureJSON(args: ["tag", "graph", "--json"])
    }

    func renameTag(old: String, new: String) async throws {
        _ = try await captureOutput(args: ["tag", "rename", "--json", old, new])
    }

    // MARK: - Collections

    func listCollections() async throws -> [StashCollection] {
        try await captureJSON(args: ["collection", "list", "--json"])
    }

    /// Sort modes for `listCollections(sortedBy:limit:)`. Maps to
    /// `stash collection list --sort` on the CLI.
    enum CollectionSort: String {
        case name      // alphabetical
        case recent    // newest MAX(item_collections.added_at) first
        case frequent  // highest view_count first
    }

    /// Fetch a sorted slice of collections. limit = 0 means all.
    /// Backs the Mac sidebar's cap-at-3 Recent/Frequent display.
    func listCollections(sortedBy sort: CollectionSort, limit: Int = 0) async throws -> [StashCollection] {
        var args = ["collection", "list", "--json", "--sort", sort.rawValue]
        if limit > 0 {
            args += ["--limit", "\(limit)"]
        }
        return try await captureJSON(args: args)
    }

    /// Bump view_count on the given collection. Called when the
    /// user clicks a Static Collection in the sidebar so the
    /// Frequent sort tracks actual usage. Fire-and-forget: we
    /// don't await the result for navigation responsiveness.
    func touchCollection(name: String) async throws {
        _ = try await captureOutput(args: ["collection", "touch", name])
    }

    /// Merge `others` into `survivor` (Static-only). The CLI runs
    /// everything in a single transaction; folded items append at
    /// the end of the survivor's existing curated order. Duplicate
    /// memberships collapse silently.
    func mergeCollections(survivor: String, others: [String]) async throws {
        var args = ["collection", "merge", "--into", survivor]
        args.append(contentsOf: others)
        _ = try await captureOutput(args: args)
    }

    /// Add items from one or more source collections (Static OR
    /// Smart) to one or more destination collections (Static only).
    /// Optionally creates a new Static destination on the fly —
    /// the primary path for "snapshot a Smart Collection's current
    /// results into a durable Static one." Upsert semantics: items
    /// already in a destination are no-ops.
    func addItemsToCollections(
        from sources: [String],
        to destinations: [String],
        createNew: String? = nil,
        newDescription: String? = nil
    ) async throws {
        var args = ["collection", "add-to"]
        for src in sources {
            args += ["--from", src]
        }
        for dest in destinations {
            args += ["--to", dest]
        }
        if let createNew, !createNew.isEmpty {
            args += ["--create", createNew]
            if let newDescription, !newDescription.isEmpty {
                args += ["--description", newDescription]
            }
        }
        _ = try await captureOutput(args: args)
    }

    func createCollection(name: String, description: String? = nil) async throws -> StashCollection {
        var args = ["collection", "create", "--json", name]
        if let description { args += ["-d", description] }
        return try await captureJSON(args: args)
    }

    /// Set the curated order of items in a collection. The full
    /// desired order is sent via stdin (one id per line) so we don't
    /// hit argv length limits with large collections. Items in the
    /// collection but not listed retain their existing positions
    /// (which may now collide with new positions, ambiguous order).
    /// The Mac caller is expected to always pass the full list.
    func collectionReorder(name: String, ids: [String]) async throws {
        let payload = ids.joined(separator: "\n")
        _ = try await executeWithStdin(
            args: ["collection", "reorder", name, "-", "--json"],
            input: payload
        )
    }

    func deleteCollection(name: String) async throws {
        _ = try await captureOutput(args: ["collection", "delete", "--json", name])
    }

    // MARK: - Saved Searches

    func listSavedSearches() async throws -> [SavedSearch] {
        try await captureJSON(args: ["search", "list", "--json"])
    }

    func runSavedSearch(name: String) async throws -> [StashItem] {
        try await captureJSON(args: ["search", "run", "--json", name])
    }

    func deleteSavedSearch(name: String) async throws {
        _ = try await captureOutput(args: ["search", "delete", "--json", name])
    }

    func renameSavedSearch(oldName: String, newName: String) async throws {
        _ = try await captureOutput(args: ["search", "rename", "--json", oldName, newName])
    }

    /// Create or upsert a Smart Collection by name. `stash search save`
    /// is itself an upsert (ON CONFLICT DO UPDATE), so this also serves
    /// as the "edit" path.
    func saveSearch(name: String, query: String, filter: SavedSearch.SearchFilter) async throws {
        var args = ["search", "save", "--json", "--live"]
        if let t = filter.type, !t.isEmpty {
            args += ["--type", t]
        }
        if let tags = filter.tags {
            for tag in tags { args += ["--tag", tag] }
        }
        if let xs = filter.excludeTags {
            for tag in xs { args += ["--exclude-tag", tag] }
        }
        if filter.untagged == true {
            args.append("--untagged")
        }
        if let c = filter.collection, !c.isEmpty {
            args += ["--collection", c]
        }
        if let r = filter.recent, !r.isEmpty {
            args += ["--recent", r]
        }
        if let rx = filter.regex, !rx.isEmpty {
            args += ["--regex", rx]
        }
        if let l = filter.limit, l > 0 {
            args += ["--limit", "\(l)"]
        }
        // Positional args: name, then query (only if non-empty —
        // empty query positional confuses cobra).
        args.append(name)
        if !query.isEmpty {
            args.append("--")
            args.append(query)
        }
        _ = try await captureOutput(args: args)
    }

    // MARK: - Duplicates

    func dupes(type: ItemType? = nil, threshold: Double = 0.7) async throws -> [DupeResult] {
        var args = ["dupes", "--json", "--threshold", "\(threshold)"]
        if let type { args += ["--type", type.rawValue] }
        return try await captureJSON(args: args)
    }

    // MARK: - Duplicate Dismissal

    func dismissDupePair(idA: String, idB: String) async throws {
        _ = try await captureOutput(args: ["dupes", "dismiss", idA, idB])
    }

    // MARK: - Stats & Check

    func stats() async throws -> StashStatsResponse {
        try await captureJSON(args: ["stats", "--json"])
    }

    func check(urls: Bool = true, files: Bool = true, dupes: Bool = true) async throws -> CheckResult {
        var args = ["check", "--json"]
        if !urls || !files || !dupes {
            if urls { args.append("--urls") }
            if files { args.append("--files") }
            if dupes { args.append("--dupes") }
        }
        return try await captureJSON(args: args)
    }

    /// Streams `stash check --stream` output as NDJSON events. Each line of
    /// stdout is decoded into a `CheckEvent` and yielded as soon as it arrives,
    /// so callers can render findings progressively.
    nonisolated func checkStream(urls: Bool = true, files: Bool = true, dupes: Bool = true) -> AsyncThrowingStream<CheckEvent, Error> {
        var args = ["check", "--stream"]
        if !urls || !files || !dupes {
            if urls { args.append("--urls") }
            if files { args.append("--files") }
            if dupes { args.append("--dupes") }
        }

        return AsyncThrowingStream { continuation in
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase

            Task.detached(priority: .userInitiated) { [args] in
                let binaryPath = await self.binaryPath
                process.executableURL = URL(fileURLWithPath: binaryPath)
                process.arguments = args

                do {
                    try process.run()
                } catch {
                    continuation.finish(throwing: error)
                    return
                }

                let handle = stdout.fileHandleForReading
                var buffer = Data()

                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    buffer.append(chunk)

                    while let newlineIdx = buffer.firstIndex(of: 0x0A) {
                        let lineData = buffer.subdata(in: 0..<newlineIdx)
                        buffer.removeSubrange(0...newlineIdx)
                        if lineData.isEmpty { continue }
                        if let event = try? decoder.decode(CheckEvent.self, from: lineData) {
                            continuation.yield(event)
                        }
                        // Malformed lines (e.g. stray log output) are skipped
                        // rather than aborting the whole stream.
                    }
                }

                process.waitUntilExit()

                if process.terminationStatus != 0 {
                    let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                    let errMsg = String(data: errData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "check failed"
                    continuation.finish(throwing: CLIError.failed(errMsg))
                    return
                }

                continuation.finish()
            }

            continuation.onTermination = { _ in
                if process.isRunning {
                    process.terminate()
                }
            }
        }
    }

    // MARK: - Rules

    func listRules() async throws -> [Rule] {
        try await captureJSON(args: ["rules", "list", "--json"])
    }

    func testRule(itemID: String) async throws -> RuleTestResult {
        try await captureJSON(args: ["rules", "test", "--json", itemID])
    }

    func setRuleEnabled(name: String, enabled: Bool) async throws {
        let verb = enabled ? "enable" : "disable"
        _ = try await captureOutput(args: ["rules", verb, "--json", name])
    }

    /// Upsert a rule by piping its JSON form to `stash rules save`. The
    /// rule's `name` is the upsert key — saving a rule with the same name
    /// replaces the existing one in the YAML, preserving comments.
    func saveRule(_ rule: Rule) async throws {
        let data = try encoder.encode(rule)
        let payload = String(data: data, encoding: .utf8) ?? "{}"
        _ = try await executeWithStdin(args: ["rules", "save", "--json"], input: payload)
    }

    func removeRule(name: String) async throws {
        _ = try await captureOutput(args: ["rules", "remove", "--json", name])
    }

    /// Rename a rule. Updates rules.yaml in place and rewrites rules.log
    /// so historical activity stays attached to the rule under its new
    /// name. Errors if `newName` collides with an existing rule.
    func renameRule(oldName: String, newName: String) async throws {
        _ = try await captureOutput(args: ["rules", "rename", "--json", oldName, newName])
    }

    /// Run rules over existing items. `ruleName` limits the run to a single
    /// rule; nil applies all enabled rules. When `dryRun` is true no writes
    /// happen but the returned summary lists the would-be changes.
    func applyRules(ruleName: String? = nil, dryRun: Bool = false) async throws -> RuleApplySummary {
        var args = ["rules", "apply", "--json"]
        if let ruleName { args += ["--rule", ruleName] }
        if dryRun { args.append("--dry-run") }
        return try await captureJSON(args: args)
    }

    /// Read the rules activity log. Calls `stash rules log --json` which
    /// emits JSONL (one Event per line); we decode line-by-line because
    /// the log isn't a single JSON document. Returns events newest-first
    /// (the CLI orders them that way already).
    ///
    /// Filters mirror the CLI flags. Pass nil to skip a filter.
    func listRuleEvents(
        type: RuleEvent.EventType? = nil,
        rule: String? = nil,
        limit: Int = 100,
        since: String? = nil
    ) async throws -> [RuleEvent] {
        var args = ["rules", "log", "--json", "-l", "\(limit)"]
        if let type { args += ["--type", type.rawValue] }
        if let rule { args += ["--rule", rule] }
        if let since { args += ["--since", since] }
        let output = try await captureOutput(args: args)
        return decodeJSONLines(output, as: RuleEvent.self)
    }

    /// Decode line-delimited JSON. Empty lines and parse errors are
    /// skipped — the rules log can in principle contain a corrupt entry
    /// (process killed mid-write), and we want to render the rest.
    private func decodeJSONLines<T: Decodable>(_ output: String, as: T.Type) -> [T] {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: true)
        return lines.compactMap { line -> T? in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(T.self, from: data)
        }
    }

    // MARK: - Bulk Operations

    func bulkTag(ids: [String], addTags: [String] = [], removeTags: [String] = []) async throws {
        var args = ["bulk", "tag", "--json"]
        for tag in addTags { args += ["--add-tag", tag] }
        for tag in removeTags { args += ["--remove-tag", tag] }
        args += ids
        _ = try await captureOutput(args: args)
    }

    func bulkDelete(ids: [String]) async throws {
        var args = ["bulk", "delete", "--json", "-y"]
        args += ids
        _ = try await captureOutput(args: args)
    }

    /// Archive an item (soft-delete — hides from default list/search,
    /// recoverable via `stash unarchive`). Mirrors the gostash CLI's
    /// `stash archive <id>...` which accepts one or more IDs.
    func archiveItems(ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        var args = ["archive", "--json"]
        args += ids
        _ = try await captureOutput(args: args)
    }

    func askAI(itemID: String, question: String) async throws -> StashItem {
        return try await captureJSON(args: ["edit", "--json", itemID, "--ask-ai", "--ask-question", question])
    }

    func reindex() async throws {
        _ = try await captureOutput(args: ["reindex"])
    }

    func cleanOrphans() async throws -> Int {
        struct CleanResult: Decodable { let orphans_deleted: Int }
        let res: CleanResult = try await captureJSON(args: ["clean-orphans", "--json"])
        return res.orphans_deleted
    }

    func fixSpelling(text: String) async throws -> String {
        return try await aiTransform(kind: "fix", text: text)
    }

    func summarize(text: String) async throws -> String {
        return try await aiTransform(kind: "summary", text: text)
    }

    func suggestTags(text: String) async throws -> String {
        return try await aiTransform(kind: "tags", text: text)
    }

    private func aiTransform(kind: String, text: String) async throws -> String {
        struct TransformResult: Decodable { let result: String }
        // The backend expects a POST body, but our CLI captureJSON(args:)
        // only supports GET with args. Let's add a proper POST handler
        // or use captureJSONWithStdin if the backend supports it.
        // Actually, the current captureJSON uses the HTTP client to the
        // local server. I need a way to send a POST body.
        return try await captureJSONWithStdin(args: ["ai-\(kind)", "--json"], input: text)
    }

    func createBackup(dbOnly: Bool = false) async throws {
        var args = ["backup"]
        if dbOnly { args += ["--db-only"] }
        _ = try await captureOutput(args: args)
    }

    func unarchiveItems(ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        var args = ["unarchive", "--json"]
        args += ids
        _ = try await captureOutput(args: args)
    }

    func bulkCollect(ids: [String], collection: String, remove: Bool = false) async throws {
        var args = ["bulk", "collect", "--json", "-c", collection]
        if remove { args.append("--remove") }
        args += ids
        _ = try await captureOutput(args: args)
    }

    // MARK: - Search History

    /// Pull the Recent / Frequent rollup. `sort` is "recent" or
    /// "frequent". Drives the Quick Search browse panes when the
    /// query is empty.
    func listSearchHistory(sort: String = "recent", limit: Int = 30) async throws -> [SearchHistoryEntry] {
        try await captureJSON(args: [
            "search-history", "list",
            "--json",
            "--sort", sort,
            "-l", "\(limit)",
        ])
    }

    /// Record a committed-query event — fired when the user actually
    /// clicks a result, not on every keystroke. itemID is logged for
    /// future stats but unused by the rollup today.
    func recordSearchClick(query: String, itemID: String? = nil) async throws {
        var args = ["search-history", "record", query]
        if let itemID, !itemID.isEmpty {
            args += ["--item-id", itemID]
        }
        _ = try await captureOutput(args: args)
    }

    func clearSearchHistory() async throws {
        _ = try await captureOutput(args: ["search-history", "clear"])
    }

    func deleteSearchHistoryEntry(query: String) async throws {
        _ = try await captureOutput(args: ["search-history", "delete", query])
    }

    // MARK: - Feeds + Inbox

    /// `stash feeds list --json`
    func listFeedSources() async throws -> [FeedSource] {
        try await captureJSON(args: ["feeds", "list", "--json"])
    }

    /// `stash feeds add NAME URL ...`
    @discardableResult
    func addFeedSource(name: String,
                       url: String,
                       kind: String = "rss",
                       defaultTags: [String] = [],
                       defaultCollection: String? = nil,
                       autoStash: Bool = false,
                       intervalMinutes: Int = 360) async throws -> FeedSource {
        var args = ["feeds", "add", "--json", "--kind", kind, "--interval", "\(intervalMinutes)"]
        for t in defaultTags { args += ["-T", t] }
        if let c = defaultCollection, !c.isEmpty { args += ["-c", c] }
        if autoStash { args.append("--auto-stash") }
        args += [name, url]
        return try await captureJSON(args: args)
    }

    /// `stash feeds remove ID`
    func removeFeedSource(id: Int64) async throws {
        _ = try await captureOutput(args: ["feeds", "remove", "\(id)"])
    }

    /// `stash feeds refresh` — runs the poller across all enabled
    /// sources (or one if `sourceID` given). Returns success/failure
    /// per source via the embedded result map.
    func refreshFeeds(sourceID: Int64? = nil) async throws {
        var args = ["feeds", "refresh", "--json"]
        if let id = sourceID { args += ["--source", "\(id)"] }
        _ = try await captureOutput(args: args)
    }

    /// `stash feeds candidates --json` — Inbox view data.
    func listFeedCandidates(state: String = "unread", limit: Int = 100) async throws -> [FeedCandidate] {
        try await captureJSON(args: [
            "feeds", "candidates", "--json",
            "--state", state,
            "-l", "\(limit)",
        ])
    }

    func stashFeedCandidate(id: Int64,
                            extraTags: [String] = [],
                            collection: String? = nil,
                            notes: String? = nil) async throws -> StashItem {
        var args = ["feeds", "stash", "--json"]
        for t in extraTags { args += ["-T", t] }
        if let c = collection, !c.isEmpty { args += ["-c", c] }
        if let n = notes, !n.isEmpty { args += ["-n", n] }
        args.append("\(id)")
        return try await captureJSON(args: args)
    }

    func dismissFeedCandidate(id: Int64) async throws {
        _ = try await captureOutput(args: ["feeds", "dismiss", "\(id)"])
    }

    /// `stash feeds snooze ID --for 1h` (Go's time.Duration accepts
    /// "1h", "30m", "1h30m" — we pass through the user's choice).
    func snoozeFeedCandidate(id: Int64, duration: String) async throws {
        _ = try await captureOutput(args: ["feeds", "snooze", "\(id)", "--for", duration])
    }

    // MARK: - Resurface

    /// `stash resurface --mark` so picks don't repeat within MinIdleAgo.
    func pickResurfaceItems(limit: Int = 5) async throws -> [StashItem] {
        try await captureJSON(args: ["resurface", "--json", "-l", "\(limit)", "--mark"])
    }

    func dismissResurfaceItem(id: String) async throws {
        _ = try await captureOutput(args: ["resurface", "dismiss", id])
    }

    func snoozeResurfaceItem(id: String, duration: String) async throws {
        _ = try await captureOutput(args: ["resurface", "snooze", id, "--for", duration])
    }

    /// Items the user has flagged for action via `read-later` or
    /// `watch-later` tags. Powers the Inbox's "To read & watch"
    /// queue section. Items snoozed/dismissed for resurface are
    /// still returned — the queue is intentional commitment, not
    /// a passive resurface, so the user shouldn't lose track of
    /// what they signed up for.
    func listReadWatchQueue(limit: Int = 8) async throws -> [StashItem] {
        try await listItems(tags: ["read-later", "watch-later"], limit: limit)
    }

    /// `stash provenance <id> --json` — chronological timeline of
    /// capture / rule / tag events for one item. Used by the detail
    /// pane's "Why is this here?" section.
    func itemProvenance(id: String) async throws -> [ProvenanceEvent] {
        try await captureJSON(args: ["provenance", "--json", id])
    }

    /// `stash related <id> --json` — items scored by tag/link/domain/
    /// content-hash overlap with the source item. Drives the
    /// "Related items" section in the detail pane.
    func relatedItems(id: String, limit: Int = 5) async throws -> [StashItem] {
        try await captureJSON(args: ["related", "--json", "-l", "\(limit)", id])
    }

    // MARK: - Private

    private func captureJSON<T: Decodable>(args: [String]) async throws -> T {
        let output = try await captureOutput(args: args)
        guard let data = output.data(using: .utf8) else {
            throw CLIError.failed("Invalid UTF-8 output")
        }
        return try decodeOrExplain(T.self, from: data, args: args, raw: output)
    }

    private func captureJSONWithStdin<T: Decodable>(args: [String], input: String) async throws -> T {
        let output = try await executeWithStdin(args: args, input: input)
        guard let data = output.data(using: .utf8) else {
            throw CLIError.failed("Invalid UTF-8 output")
        }
        return try decodeOrExplain(T.self, from: data, args: args, raw: output)
    }

    /// Decode with the shared decoder and, on failure, rewrap the
    /// `DecodingError` into a `CLIError.failed` whose message names the
    /// failing JSON path and the command that produced it. Without
    /// this, every decode failure surfaces in the UI as the useless
    /// "The data couldn't be read because it is missing." default —
    /// no field, no command, no clue.
    private func decodeOrExplain<T: Decodable>(_ type: T.Type, from data: Data, args: [String], raw: String) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch let e as DecodingError {
            let cmd = "stash " + args.joined(separator: " ")
            let path = decodingPath(e)
            let kind = decodingKind(e)
            let snippet = raw.count > 200 ? String(raw.prefix(200)) + "…" : raw
            throw CLIError.failed("\(kind) at `\(path)` while running `\(cmd)`. JSON head: \(snippet)")
        }
    }

    private func decodingPath(_ e: DecodingError) -> String {
        let ctx: DecodingError.Context
        switch e {
        case .keyNotFound(_, let c),
             .valueNotFound(_, let c),
             .typeMismatch(_, let c),
             .dataCorrupted(let c):
            ctx = c
        @unknown default:
            return "<unknown>"
        }
        let parts = ctx.codingPath.map { key -> String in
            if let i = key.intValue { return "[\(i)]" }
            return key.stringValue
        }
        return parts.isEmpty ? "<root>" : parts.joined(separator: ".")
    }

    private func decodingKind(_ e: DecodingError) -> String {
        switch e {
        case .keyNotFound(let k, _):       return "Missing key '\(k.stringValue)'"
        case .valueNotFound(let t, _):     return "Missing value of type \(t)"
        case .typeMismatch(let t, _):      return "Type mismatch (expected \(t))"
        case .dataCorrupted(let c):        return "Data corrupted (\(c.debugDescription))"
        @unknown default:                  return "Unknown decode error"
        }
    }

    private func captureOutput(args: [String]) async throws -> String {
        let binary = binaryPath
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: binary)
                    process.arguments = args

                    let stdout = Pipe()
                    let stderr = Pipe()
                    process.standardOutput = stdout
                    process.standardError = stderr

                    try process.run()

                    // Read pipe data BEFORE waitUntilExit to prevent deadlock
                    // when output exceeds the pipe buffer (64KB)
                    let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                    let errData = stderr.fileHandleForReading.readDataToEndOfFile()

                    process.waitUntilExit()

                    let output = String(data: outData, encoding: .utf8) ?? ""

                    if process.terminationStatus != 0 {
                        let errOutput = String(data: errData, encoding: .utf8) ?? ""
                        let raw = errOutput.isEmpty ? output : errOutput
                        let message = Self.extractErrorMessage(raw)
                        continuation.resume(throwing: CLIError.failed(message))
                    } else {
                        continuation.resume(returning: output.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func executeWithStdin(args: [String], input: String) async throws -> String {
        let binary = binaryPath
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: binary)
                    process.arguments = args

                    let stdin = Pipe()
                    let stdout = Pipe()
                    let stderr = Pipe()
                    process.standardInput = stdin
                    process.standardOutput = stdout
                    process.standardError = stderr

                    try process.run()

                    if let data = input.data(using: .utf8) {
                        stdin.fileHandleForWriting.write(data)
                    }
                    stdin.fileHandleForWriting.closeFile()

                    let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                    let errData = stderr.fileHandleForReading.readDataToEndOfFile()

                    process.waitUntilExit()

                    let output = String(data: outData, encoding: .utf8) ?? ""

                    if process.terminationStatus != 0 {
                        let errOutput = String(data: errData, encoding: .utf8) ?? ""
                        let raw = errOutput.isEmpty ? output : errOutput
                        let message = Self.extractErrorMessage(raw)
                        continuation.resume(throwing: CLIError.failed(message))
                    } else {
                        continuation.resume(returning: output.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Pull a one-line, user-facing error from a CLI's stderr.
    /// cobra prefixes the actionable message with `Error: `; if we
    /// see that, return the rest of that line. Otherwise fall back
    /// to the trimmed first non-empty line. Strips the trailing
    /// `Usage:`-and-onward block that cobra historically appended
    /// before we set `SilenceUsage` (defensive in case any stderr
    /// path bypasses that flag).
    static func extractErrorMessage(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Unknown error" }
        for line in trimmed.split(separator: "\n", omittingEmptySubsequences: false) {
            let candidate = String(line).trimmingCharacters(in: .whitespaces)
            if candidate.isEmpty { continue }
            if let prefixRange = candidate.range(of: "Error: ") {
                return String(candidate[prefixRange.upperBound...])
            }
            // First non-empty line, before any "Usage:" block.
            if candidate == "Usage:" { break }
            return candidate
        }
        return trimmed
    }
}

enum CLIError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let msg): return msg
        }
    }
}
