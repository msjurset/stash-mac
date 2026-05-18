import Foundation

enum HelpSection {
    case heading(String)
    case subheading(String)
    case paragraph(String)
    case code(String)
    case table(headers: [String], rows: [[String]])
    case bullet([String])
    case numbered([String])
}

enum HelpTopic: String, CaseIterable, Identifiable, Codable, Hashable {
    case gettingStarted = "Getting Started"
    case addingItems = "Adding Items"
    case itemTypes = "Item Types"
    case organizing = "Tags, Collections & Links"
    case searching = "Searching"
    case itemDetail = "Item Detail"
    case dragAndDrop = "Drag & Drop"
    case cliIntegration = "CLI Integration"
    case savedSearches = "Saved Searches"
    case duplicates = "Duplicates"
    case statsAndCheck = "Stats & Health Check"
    case clipboard = "Clipboard Quick-Stash"
    case services = "System Services"
    case rules = "Rules"
    case aiIdentify = "Identify with AI"
    case location = "Location"
    case trips = "Trip Suggestions"
    case keyboard = "Keyboard Shortcuts"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .gettingStarted: return "star"
        case .addingItems: return "plus.circle"
        case .itemTypes: return "square.grid.2x2"
        case .organizing: return "tag"
        case .searching: return "magnifyingglass"
        case .itemDetail: return "doc.text"
        case .dragAndDrop: return "arrow.down.doc"
        case .cliIntegration: return "terminal"
        case .savedSearches: return "magnifyingglass.circle"
        case .duplicates: return "doc.on.doc"
        case .statsAndCheck: return "chart.bar"
        case .clipboard: return "doc.on.clipboard"
        case .services: return "square.and.arrow.down.on.square"
        case .rules: return "wand.and.stars"
        case .aiIdentify: return "sparkles"
        case .location: return "mappin.and.ellipse"
        case .trips: return "calendar.badge.clock"
        case .keyboard: return "keyboard"
        }
    }

    var sections: [HelpSection] {
        switch self {
        case .gettingStarted:
            return [
                .paragraph("Stash is a personal content manager for storing and organizing links, files, snippets, images, and emails. The Mac app is a frontend for the stash CLI — all data is managed by the CLI's storage engine."),
                .heading("Quick Start"),
                .numbered([
                    "Add an item — Press ⌘N or click the + button in the toolbar",
                    "Choose a type — Select the URL, File, or Snippet tab",
                    "Organize — Add tags and assign a collection",
                    "Browse — Use the sidebar to filter by type, tag, or collection",
                    "Search — Press ⌘K for quick search across all items",
                ]),
                .heading("Requirements"),
                .bullet([
                    "macOS 15.0 (Sequoia) or later",
                    "The stash CLI installed and available in your PATH",
                ]),
            ]

        case .addingItems:
            return [
                .paragraph("Press ⌘N to open the Add Item sheet. Choose a tab for the type of content you want to stash."),
                .heading("URL"),
                .paragraph("Paste a web link. Stash fetches the page title and extracts readable text automatically."),
                .heading("File"),
                .paragraph("Enter a file path or click Browse to use the file picker. The file is copied into the stash store — the original is not modified."),
                .heading("Snippet"),
                .paragraph("Paste or type any text content. Useful for code fragments, notes, or log entries."),
                .heading("Common Fields"),
                .table(headers: ["Field", "Description"], rows: [
                    ["Title", "Optional display name (auto-generated if blank)"],
                    ["Tags", "Comma-separated list of tags to apply"],
                    ["Note", "Optional annotation or context"],
                    ["Collection", "Assign to an existing collection"],
                ]),
                .heading("Drag & Drop"),
                .paragraph("You can also add files by dragging them directly onto the app window."),
            ]

        case .itemTypes:
            return [
                .paragraph("Every stashed item has a type that determines its icon and behavior."),
                .table(headers: ["Type", "Icon", "Description"], rows: [
                    ["URL", "🌐", "Web URLs — title and text are extracted from the page"],
                    ["Snippet", "📄", "Text content stored inline"],
                    ["File", "📁", "Any file — copied into the stash store"],
                    ["Image", "🖼️", "Image files with preview support"],
                    ["Email", "✉️", "Email messages (.eml files)"],
                ]),
                .paragraph("The type is set automatically when you add an item. Filter by type using the sidebar under Library."),
            ]

        case .organizing:
            return [
                .paragraph("Stash offers three ways to organize items, each serving a different purpose."),
                .heading("Tags — What is it about?"),
                .paragraph("Flat labels describing the content's topic or nature. An item can have many tags. Use tags for filtering, searching, and cross-cutting categories. Tags answer \"show me everything about X.\""),
                .bullet([
                    "Add tags when creating or editing an item (comma-separated)",
                    "Browse all tags in the sidebar Tags section",
                    "Click a tag in the item detail view to filter by it",
                    "Right-click a tag in the sidebar to rename it",
                    "Tags are shared across all items — renaming updates every item with that tag",
                ]),
                .heading("Collections — Where does it belong?"),
                .paragraph("Named groups, like folders or projects. An item belongs to one collection (or none). Use collections for grouping items by purpose, project, or workflow. Collections answer \"show me everything for project Y.\""),
                .bullet([
                    "Collections group related items together (e.g., \"Job Search\", \"Home Renovation\")",
                    "Create a collection from the sidebar or when adding/editing an item",
                    "Each item can belong to one collection",
                    "Right-click a collection in the sidebar to delete it",
                ]),
                .heading("Links — How does it relate to other items?"),
                .paragraph("Direct relationships between specific items. Bidirectional or directed, with optional labels. Use links for connecting a source to its reference, or grouping related items that aren't topically similar. Links answer \"what's connected to this specific item?\""),
                .bullet([
                    "Link items from the detail view toolbar (link icon or ⌘L)",
                    "Search for the target item by name, then add an optional label",
                    "Linked items appear in the detail view with directional arrows",
                    "Example: link a PDF resume to the job posting URL it was submitted for",
                ]),
                .heading("Tag Graph — How do topics cluster?"),
                .paragraph("The Tag Graph (in the Library section of the sidebar) reveals how your topics overlap. Tags that frequently co-occur on the same items form strong connections. Click a node to filter items by that tag. The graph helps you discover relationships between topics you might not have noticed."),
                .heading("Managing Tags on an Item"),
                .paragraph("Open the Edit sheet (pencil icon or context menu) to add or remove individual tags. Existing tags are shown as removable capsules, and you can type new ones in the text field."),
            ]

        case .searching:
            return [
                .heading("Quick Search Panel"),
                .paragraph("Open the global search panel with ⌘F, ⌘K, or `/`. Results update in real time as you type. Use ↑/↓ (or Ctrl-J/K) to move the highlight, Return to jump to the highlighted result, Escape to dismiss. Selecting a result that lives outside your current sidebar scope automatically switches to All Items so the row is visible and highlighted."),
                .paragraph("Pressing `/` always opens the panel when no field has focus. When the list filter field has focus *and is empty* (the common state on first launch), `/` opens the panel as well — that way you don't have to click anywhere first. Mid-text `/` stays a literal character so you can include slashes in queries."),
                .heading("Tag Completion"),
                .paragraph("Type `tag:` inside the panel to bring up tag suggestions. Tab cycles, Return commits. Repeat for multiple tags. Tag tokens compose with the rest of the free-text query."),
                .heading("Regex Mode"),
                .paragraph("Click the * button next to the field (or press ⌘R) to switch to RE2 regex. The pattern matches against title + notes + URL + extracted text. A small popover opens with a syntax cheatsheet that stays visible while you type — click outside the panel to dismiss."),
                .bullet([
                    "Prefix the pattern with `!` to negate the match (e.g. `!^https://` for items whose URL doesn't start with https).",
                    "Tag filters are disabled in regex mode — `tag:` may be a literal in your pattern.",
                    "The pattern is pre-validated client-side; bad syntax surfaces an inline warning under the field instead of silently empty results.",
                ]),
                .heading("List Filter"),
                .paragraph("The search field at the top of the item list filters items within the current sidebar selection. Press Return to search, or clear the field to show all items. Free-text only — for regex use the global panel."),
                .heading("Combining Filters"),
                .paragraph("Select a type, tag, or collection in the sidebar first, then use the list search to narrow further. For example, select URLs in the sidebar, then search for \"api\" to find only URL items matching that term."),
            ]

        case .itemDetail:
            return [
                .paragraph("Selecting an item in the list (single-click) populates the right-hand pane with its full record. The pane is read-only by default; the Edit button at the top opens an inline editor."),
                .heading("Pane Sections"),
                .paragraph("The detail pane stacks the following sections, in order. The list below describes what each one shows in the app — these aren't clickable links inside this help window."),
                .table(headers: ["Section", "Description"], rows: [
                    ["Header", "Type icon, title, and short ID"],
                    ["Player", "Inline AVKit player for audio/video files and direct-stream URLs (video has fullscreen toggle)"],
                    ["Thumbnail", "128pt preview tile. Drop an image to override; menu offers Generate, Set from URL/file, and Clear"],
                    ["URL", "Clickable link (for URL items)"],
                    ["Notes", "Your annotation text — double-click to open a popout editor"],
                    ["Tags", "Tag capsules with # prefix"],
                    ["Collections", "Folder labels for assigned collections"],
                    ["File Info", "MIME type, file size, and source path"],
                    ["Archive Contents", "Interactive tree view of tar.gz and zip archive contents"],
                    ["Extracted Text", "Content extracted from links/files (collapsible) — double-click to open a popout editor"],
                    ["Dates", "Created and last updated timestamps"],
                ]),
                .heading("Actions"),
                .bullet([
                    "Open — Launch the item in its default app (browser for links, Finder for files)",
                    "Edit — Modify title, notes, extracted text, tags, and collection",
                    "Delete — Permanently remove the item (with confirmation)",
                ]),
                .paragraph("All text fields support selection and copying."),
            ]

        case .dragAndDrop:
            return [
                .paragraph("Drag one or more files from Finder onto the Stash window to add them instantly."),
                .heading("How It Works"),
                .numbered([
                    "Drag a file onto any part of the app window",
                    "The file is copied into the stash store via the CLI",
                    "The item appears in your list with an auto-generated title",
                    "Edit the item afterward to add tags, notes, or a collection",
                ]),
                .paragraph("Drag and drop supports any file type the stash CLI can handle, including documents, images, archives, and more."),
            ]

        case .cliIntegration:
            return [
                .paragraph("The Mac app delegates all operations to the stash CLI binary. It does not store data itself."),
                .heading("CLI Commands Used"),
                .table(headers: ["Command", "Purpose"], rows: [
                    ["stash list", "Browse items with filters"],
                    ["stash search", "Full-text search"],
                    ["stash show", "Get item details by ID"],
                    ["stash add", "Store URLs, files, or snippets"],
                    ["stash edit", "Modify item metadata and extracted text"],
                    ["stash delete", "Remove an item"],
                    ["stash open", "Open item in default app"],
                    ["stash tag list/rename", "Manage tags"],
                    ["stash collection list/create/delete", "Manage collections"],
                    ["stash stats", "Stash statistics and storage usage"],
                    ["stash check", "Data hygiene — find broken URLs, orphaned files, duplicates"],
                    ["stash bulk tag/delete/collect", "Bulk operations on multiple items"],
                    ["stash search save/list/run/delete", "Saved searches"],
                    ["stash dupes", "Find duplicate items"],
                    ["stash thumbnail set/clear/path", "Manage per-item thumbnails (manual override + Mac-app pipeline)"],
                ]),
                .heading("Binary Location"),
                .paragraph("The app searches for the stash binary in these locations, using the first one found:"),
                .bullet([
                    "~/.local/bin/stash",
                    "~/go/bin/stash",
                    "/usr/local/bin/stash",
                    "/opt/homebrew/bin/stash",
                ]),
                .heading("Data Format"),
                .paragraph("All communication uses JSON output mode (--json flag). The CLI manages its own storage — the app never reads or writes data files directly."),
            ]

        case .savedSearches:
            return [
                .paragraph("Save frequently used searches and run them later from the sidebar."),
                .heading("Saving a Search"),
                .paragraph("Use the CLI to save a search with filters:"),
                .code("stash search save my-search --type url --tag go"),
                .paragraph("Saved searches appear in the Saved Searches section of the sidebar."),
                .heading("Running a Saved Search"),
                .paragraph("Click a saved search in the sidebar to run it. The item list updates with the results."),
                .heading("Managing Saved Searches"),
                .bullet([
                    "Right-click a saved search in the sidebar to delete it",
                    "Saved searches persist across app restarts",
                    "Each search stores its query text and all filter parameters",
                ]),
            ]

        case .duplicates:
            return [
                .paragraph("The Duplicates view finds items that may be duplicates of each other."),
                .heading("Detection Methods"),
                .bullet([
                    "Same Content — items with identical file content (matching content hash)",
                    "Same URL — multiple bookmark items pointing to the same web address",
                    "Similar Title — items with titles that are very similar but not identical",
                ]),
                .heading("Using the View"),
                .paragraph("Select Duplicates in the sidebar, then click Find Duplicates to scan. Results are grouped by detection method with color coding. Click an item title to navigate to it."),
            ]

        case .statsAndCheck:
            return [
                .paragraph("The Stats and Health Check views help you understand and maintain your stash."),
                .heading("Stats"),
                .paragraph("Select Stats in the sidebar to see a dashboard with:"),
                .bullet([
                    "Total item count and breakdown by type (URL, snippet, file, image, email)",
                    "Tag, collection, and link counts",
                    "Disk storage usage (database + content files)",
                    "Top 10 most-used tags with visual bar chart",
                    "Monthly growth chart showing items added over time",
                    "Oldest and newest item dates",
                ]),
                .heading("Health Check"),
                .paragraph("Select Health Check in the sidebar, then click Run Check to scan for:"),
                .bullet([
                    "Broken URLs — links that return HTTP errors or fail to connect",
                    "Missing files — items referencing content that no longer exists on disk",
                    "Orphaned files — files on disk not referenced by any item",
                    "Duplicate content — multiple items sharing identical file content",
                ]),
                .paragraph("Results stream in progressively — each broken URL or missing file appears as soon as it's detected, so you don't have to wait for every URL to be tested before seeing findings. URL checks run in parallel, so a single slow or failing request no longer blocks the rest."),
                .paragraph("DNS-resolution failures are retried up to three times with backoff. Persistent DNS-only failures are treated as inconclusive (not flagged) — catches Pi-hole flushes and local-resolver blips that would otherwise mass-flag dozens of healthy URLs."),
                .heading("Working with Findings"),
                .bullet([
                    "Click any issue row to load that item in the detail pane on the right.",
                    "Each broken-URL row has an arrow.clockwise button that re-probes just that item without rerunning the whole scan.",
                    "Right-click → Edit URL… commits the new URL with optimistic feedback (\"<new> — rechecking…\"), then resolves to the real status; if the new URL is still broken, the row's detail updates with the new failure.",
                    "Right-click → Ask Google opens a search for \"What happened to <URL>?\" — useful for hunting down a moved page.",
                    "Delete and Archive prune the row from the list immediately — no need to rerun the check.",
                    "Each section has a small clipboard button that copies the section's contents — handy for piping into an external tool (e.g. an LLM chat) for bulk-replacement suggestions.",
                ]),
            ]

        case .clipboard:
            return [
                .paragraph("A low-friction way to capture URLs without switching to the app — copy a link, click the menubar, stash it."),
                .heading("How It Works"),
                .numbered([
                    "Click the tray icon in the menubar and toggle \"Watch Clipboard\" on — the icon fills in when active",
                    "Copy any URL from a browser, email, document, or anywhere else",
                    "Within 2 seconds, the URL appears in the menubar dropdown with a \"Stash It\" button",
                    "Click \"Stash It\" to save it to your stash instantly",
                ]),
                .heading("Menubar Features"),
                .bullet([
                    "Watch Clipboard — toggle clipboard monitoring on or off",
                    "Stash It — one-click save when a URL is detected",
                    "Recent — your last 5 quick-stashes for reference",
                    "Open Stash — bring up the main app window",
                    "Quit — exit the app entirely (not just close the window)",
                ]),
                .paragraph("The menubar icon changes to a filled tray when clipboard watching is active. Only HTTP and HTTPS URLs are detected — other clipboard content is ignored."),
            ]

        case .services:
            return [
                .paragraph("Stash registers a system Service so you can stash content from any app without switching windows. Look for \"Stash Selection\" under the right-click menu's Services submenu, or under the app menu > Services."),
                .heading("What You Can Stash"),
                .bullet([
                    "Selected text in any app — saved as a snippet, titled with the source app name",
                    "Selected files in Finder — each file added to your stash",
                    "Email body text in Mail — selected text becomes a snippet (Mail does not expose the whole message to Services, only the highlighted text)",
                ]),
                .heading("Bind a Keyboard Shortcut"),
                .numbered([
                    "Open System Settings > Keyboard > Keyboard Shortcuts > Services",
                    "Find \"Stash Selection\" under Text or Files",
                    "Click \"none\" and press your shortcut (e.g. ⌃⌥⌘S)",
                ]),
                .paragraph("After deploying, the service may take a moment (or one logout/login) to appear. The deploy step runs `pbs -update` to refresh the system's Services index."),
                .heading("Where to Find Output"),
                .paragraph("Stashed items show up in your stash like any other entry. Notifications confirm success or report errors; logs are written to /tmp/stash-services.log for troubleshooting."),
            ]

        case .rules:
            return [
                .paragraph("Capture rules let you tag, categorize, retitle, annotate, link, notify, or even drop items automatically as they're stashed. Every `stash add` runs the rules and applies any matching effects before the item is saved. Rules live at ~/.stash/rules.yaml and are managed via the sidebar's Rules entry or the `stash rules` CLI."),
                .heading("How a rule fires"),
                .numbered([
                    "Match conditions are AND-composed — all set conditions on a rule must hold for it to fire.",
                    "Multiple rules can match the same item; their effects compose by type (tags merge, collection / title / set_note are first-match-wins, append_note stacks, notify and link_to stack).",
                    "If any matched rule has a `skip` action, the item is dropped: not saved to the database, audit-logged to ~/.stash/skip.log, any pending `notify` actions still fire.",
                    "Explicit `stash add` flags (-T tags, -c collection, -t title, -n note) take precedence over rule output for those fields.",
                ]),
                .heading("Match conditions"),
                .table(headers: ["Key", "Matches"], rows: [
                    ["type", "Item type: url, file, snippet, image, email"],
                    ["domain", "URL host (case-insensitive, suffix-aware: youtube.com matches m.youtube.com)"],
                    ["url_regex", "Regex on the full URL (named groups become {{.Captures.X}})"],
                    ["mime_type", "Exact MIME-type match"],
                    ["mime_type_prefix", "Prefix match (e.g. image/ matches image/png and image/jpeg)"],
                    ["sender", "Case-insensitive substring on email From: header"],
                    ["sender_domain", "Domain match on email From: (suffix-aware)"],
                    ["path_glob", "filepath.Match-style glob on file source path or basename"],
                    ["content", "Case-insensitive substring on extracted text"],
                    ["content_regex", "Regex on extracted text (named groups become {{.Captures.X}})"],
                ]),
                .heading("Action types"),
                .table(headers: ["Action", "Effect"], rows: [
                    ["add_tags", "Apply tags to the item. Additive across rules; deduped against existing tags."],
                    ["add_collection", "Assign to a collection (auto-created if missing). First-match-wins."],
                    ["set_title", "Replace the auto-detected title. Templated. First-match-wins."],
                    ["set_note", "Replace the note field. Templated. First-match-wins."],
                    ["append_note", "Append to the note field (newline-separated). Templated. Stacks across rules."],
                    ["notify", "Fire a macOS desktop notification. Templated. Clickable when terminal-notifier is installed."],
                    ["skip", "Drop the item entirely. Audit-logged. Aborts the add — other effects don't apply."],
                    ["link_to", "Auto-link the new item to existing items by tag or by id (capped at 50 targets)."],
                ]),
                .heading("Template variables"),
                .paragraph("Set_title, set_note, append_note, and notify are rendered with Go text/template. Available variables:"),
                .bullet([
                    "{{.Title}}, {{.URL}}, {{.Domain}}, {{.Type}}, {{.MimeType}}",
                    "{{.Sender}}, {{.SenderName}}, {{.SenderEmail}}, {{.SenderDomain}}, {{.Subject}} (emails)",
                    "{{.Filename}} (basename of source path), {{.Date}} (ISO YYYY-MM-DD)",
                    "{{.Rule.Name}} — name of the rule that fired",
                    "{{.Captures.X}} — named regex capture groups from url_regex / content_regex",
                ]),
                .heading("Examples"),
                .code("""
- name: youtube
  match:
    domain: youtube.com
  actions:
    - add_tags: [video, watch-later]

- name: invoice-pdfs
  match:
    mime_type: application/pdf
    content_regex: "(?i)Total[:\\\\s]+(?P<amount>\\\\$[0-9.,]+)"
  actions:
    - add_tags: [invoice, finance]
    - add_collection: bills
    - set_title: "Invoice {{.Captures.amount}}"
    - notify: "Invoice landed: {{.Captures.amount}}"

- name: drop-spam
  match:
    type: email
    sender_domain: noreply.linkedin.com
  actions:
    - skip: true
"""),
                .heading("CLI"),
                .table(headers: ["Command", "Purpose"], rows: [
                    ["stash rules list", "Show all rules with match summary and action chips"],
                    ["stash rules test <id>", "Preview what rules would do to an existing item (no writes)"],
                    ["stash rules apply [--dry-run]", "Retroactively run rules over existing items"],
                    ["stash rules enable/disable <name>", "Toggle a rule's enabled flag"],
                    ["stash rules save", "Upsert a rule from JSON on stdin (used by the Mac editor)"],
                    ["stash rules remove <name>", "Delete a rule from the file"],
                ]),
                .heading("Notifications on macOS"),
                .paragraph("`brew install terminal-notifier` makes notify banners clickable — clicking opens the URL (link items) or source file (file/image items). Without it, notifications still fire but aren't clickable."),
                .heading("Suggest Rules (Apple Intelligence)"),
                .paragraph("On Apple Silicon Macs with Apple Intelligence enabled, the Rules toolbar's ✨ button asks the on-device language model to characterize patterns in your manual tagging history (last ~100 events from $STASH_DIR/tags.log plus the current item↔tag snapshot) and proposes new rules. Tags already covered by an enabled rule are skipped."),
                .bullet([
                    "Each card shows the proposed rule preview, the supporting items, and Add Rule / Skip buttons.",
                    "Add Rule opens the rule editor pre-populated; Create writes the rule with `enabled: false` so it doesn't tag anything until you flip the toggle and run Apply Now.",
                    "Skip persists across sessions; the sheet footer shows a count and a Reset button to bring previously-skipped patterns back.",
                    "The button greys out on Intel Macs or when Apple Intelligence isn't enabled in System Settings.",
                ]),
            ]

        case .aiIdentify:
            return [
                .paragraph("Stash can ask an AI provider to identify the subject of an image item — handy for birds, plants, products, screenshots from the field, anything where you'd rather not type out a title and notes by hand. The integration is opt-in: nothing leaves the Mac until you add an API key in Settings."),
                .heading("Setup"),
                .numbered([
                    "Open Settings (⌘,) → AI tab.",
                    "Pick a provider from the picker at the top (currently Google Gemini; Claude / OpenAI plug-ins land in the same dropdown when added).",
                    "Paste the provider's API key into the field and click Save. The key is stored in UserDefaults and never leaves this Mac except in outbound requests to that provider's endpoint.",
                    "Optionally click Test to verify the key with a small round trip.",
                    "Edit the identify prompt if you want different output shape — the parser handles `TITLE:` / `NOTES:` markers as well as `Common Name:` / `Subject:` fallbacks.",
                ]),
                .heading("Using It"),
                .bullet([
                    "Right-click any image item in the list or grid and choose Identify with <active provider>.",
                    "Title is filled only when it's currently blank — the provider doesn't overwrite a title you typed yourself.",
                    "Notes are appended (separated by a blank line) so repeat identifies on the same item don't lose earlier output.",
                    "A flash message reports progress (\"Identifying abc123… with Google Gemini\") and completion (\"Identified ✓\").",
                ]),
                .heading("1Password Integration"),
                .paragraph("Instead of pasting a raw API key, you can paste a 1Password reference: `op://Private/Stash Gemini API Key/password`. The app resolves it via the 1Password CLI (`op read`) on every request, so the actual secret never lives in UserDefaults — only the reference does."),
                .bullet([
                    "Install the CLI: `brew install 1password-cli`.",
                    "Sign in: `op signin` (or `eval $(op signin)` for a session-scoped login).",
                    "The Settings field shows a lock-shield hint when a reference is detected and `op` is available; a yellow warning if `op` isn't installed yet.",
                    "Swap keys in 1Password without touching the app — the next identify resolves the new value.",
                ]),
                .heading("Adding More Providers"),
                .paragraph("The provider list is driven by `AIProviderRegistry`. To add Claude or OpenAI: implement the `AIProvider` protocol in a new file, add a case to `AIProviderID`, and register the concrete type in the registry. The Settings picker, prefs storage, and menu wiring pick up the new entry automatically."),
                .heading("Notes"),
                .bullet([
                    "The menu item only appears for image-type items when an API key is configured.",
                    "Each provider keeps its own key and prompt; switching the picker doesn't lose other providers' values.",
                    "Mac and Android Stash share the Gemini prompt shape but maintain independent keys / drafts.",
                ]),
            ]

        case .location:
            return [
                .paragraph("Image items can carry a geolocation — typically extracted from JPEG EXIF GPS tags at capture time, but also set manually via the Edit dialog or `stash edit --location`. When present, the detail pane shows a Location row with the coordinates and an Open in Maps link."),
                .heading("How it gets filled"),
                .bullet([
                    "**EXIF (auto)** — every image stashed via the CLI, mobile app, or `stash serve` upload gets its JPEG EXIF parsed on ingest. Source badge reads `exif`.",
                    "**Mobile capture** — when the Android app captures a photo with location services on, the OS coordinates are sent alongside the file. Source badge reads `capture`. (Falls back to EXIF if the OS API isn't available.)",
                    "**Manual** — type lat / lon into the Edit dialog or run `stash edit <id> --location \"33.7547,-84.6322\"`. Source badge reads `manual`.",
                ]),
                .heading("Backfilling existing items"),
                .paragraph("Items captured before this feature shipped don't have a populated Location even if their EXIF carries GPS. Run `stash backfill-locations --all` to scan every image and lift the GPS into the structured field. Idempotent — items already populated are skipped. Use `--force` to re-extract EXIF over existing exif-sourced rows (manual / capture values are preserved)."),
                .heading("Editing"),
                .bullet([
                    "Edit dialog has two text fields under Title — lat and lon in decimal degrees. Leave both empty to clear; mixed (one filled, one empty) silently no-ops.",
                    "Clear button removes the location.",
                    "Manual edits set `source=manual`; the backfill command then won't overwrite them on a subsequent `--force` run.",
                ]),
                .heading("Open in Maps"),
                .paragraph("The Location row's link opens Apple Maps centered on the coordinates. Right-clicking gives the standard system menu (copy, etc.)."),
                .heading("Notes"),
                .bullet([
                    "HEIC images (newer iPhone format) aren't parsed by the underlying library — they decode as 'no GPS' and skip silently. Convert to JPEG first if you need them parsed.",
                    "Garbage GPS values (NaN, 0/0 Null Island, out of geographic range) are rejected; the item gets no location rather than a corrupt one.",
                    "Snippet items don't show the Location editor — geo doesn't apply.",
                ]),
            ]

        case .trips:
            return [
                .paragraph("Trip Suggestions surfaces clusters of items you captured close together in time, often sharing a location or a tag, as candidates for a single collection. Open it from the sidebar under Tools → Trips."),
                .heading("What it looks for"),
                .bullet([
                    "Bursts of items in a short time window (default: more than 3 items within 6 hours of each other, total span ≤ 5 days)",
                    "Coherence signals that boost confidence — items sharing a tag, items with GPS coordinates near each other",
                    "Items not already grouped in the same collection (those clusters are dropped automatically once you've accepted them)",
                ]),
                .heading("Refining what goes in"),
                .paragraph("Selecting a suggestion in the middle pane fills the right pane with a thumbnail grid of every item in the cluster. Click a tile to toggle whether that item gets included — accent checkmark and full brightness for in, hollow circle and dim for out. *Select all* / *Deselect all* in the header flip the whole grid. The Accept sheet then surfaces the actual count (\"adds 12 of 19 items\") so the bundle feels like a draft, not a fixed suggestion. Right-click a tile for *Open Item* to jump into its detail view — from there, ⌘[ (or the Back chevron in the toolbar) returns you to the same suggestion with your selection intact."),
                .heading("Accepting a suggestion"),
                .paragraph("Click *Accept as Collection…* on any card. The suggested name is pre-filled — it combines the dominant shared tag (if any) with the date range. Edit it before confirming. Creates the collection if it doesn't exist and adds the items still checked in the right pane; rerun is idempotent if the collection already exists."),
                .heading("Scan window"),
                .paragraph("Defaults to the last 90 days so the list reflects recent activity. Flip *Scan all history* in the header to widen to the whole stash — useful for retroactively bundling older bursts that pre-date the feature."),
                .heading("CLI equivalent"),
                .paragraph("The Mac view is a thin wrapper over `stash trip-suggest`. The same clusters surface from the terminal:"),
                .code("stash trip-suggest --json | jq '.[0]'\nstash trip-suggest accept --name \"Beach trip 2026-05\" ID ID ID"),
            ]

        case .keyboard:
            return [
                .heading("Global"),
                .paragraph("Active anywhere in the main window. The plain-key shortcuts (`/`, `?`) defer to whichever editable field has focus — they only fire when you're not actively typing into one."),
                .table(headers: ["Shortcut", "Action"], rows: [
                    ["⌘N",  "Add new item"],
                    ["⌘R",  "Reload all data from the CLI (picks up external changes)"],
                    ["⌘F",  "Open the global search panel"],
                    ["⌘K",  "Open the global search panel (same as ⌘F)"],
                    ["⌘⇧U", "Fetch Files via URL — discover images / files on a page"],
                    ["⌘⇧I", "Import Archive — round-trip a `stash export` zip back in"],
                    ["⌘[",  "Back — return to the previous navigation state (e.g. the Trips suggestion you drilled into an item from)"],
                    ["⌘]",  "Forward — redo a Back step"],
                    ["/",   "Open the global search panel (when no field has focus, or list filter is empty)"],
                    ["?",   "Open contextual help for the current sidebar section"],
                ]),
                .heading("Global Search Panel"),
                .paragraph("Active while the search panel is open."),
                .table(headers: ["Shortcut", "Action"], rows: [
                    ["↑ / ↓",       "Move the result highlight (also: Ctrl-K / Ctrl-J)"],
                    ["Return",      "Open the highlighted result; falls back to the top hit if you haven't moved the highlight"],
                    ["Tab",         "Open or cycle the tag completion dropdown"],
                    ["⌘R",          "Toggle regex mode (RE2 against title + notes + URL + extracted text)"],
                    ["Escape",      "Dismiss the tag dropdown, then clear the field, then close the panel"],
                ]),
                .heading("Item List"),
                .table(headers: ["Shortcut", "Action"], rows: [
                    ["Single-click",  "Select an item (Cmd-click extends multi-select)"],
                    ["Double-click",  "Open the item in its default app (browser, viewer, etc.)"],
                    ["Spacebar",      "QuickLook preview of the selected item"],
                    ["Return",        "Search with the current list-filter query"],
                    ["Right-click",   "Per-item menu: Open, Edit, Tags…, Thumbnail actions, Archive, Delete"],
                    ["Drag",          "Drag onto a sidebar tag/collection to add membership; drop on a tile within a collection (curated mode) to reorder"],
                ]),
                .heading("Item Detail Pane"),
                .table(headers: ["Shortcut", "Action"], rows: [
                    ["⌘L",                 "Open the item's link / file"],
                    ["⌘O",                 "Same — Open"],
                    ["⌘E",                 "Edit the item"],
                    ["⌘⌫",                "Delete the item (with confirmation)"],
                    ["Double-click title", "Edit the title in place (click away or press Enter to save)"],
                    ["Double-click Notes", "Open the popout Notes editor"],
                    ["Double-click Extracted Text", "Open the popout Extracted Text editor"],
                ]),
                .heading("Rule Detail"),
                .table(headers: ["Shortcut", "Action"], rows: [
                    ["⌘E", "Edit the selected rule"],
                ]),
                .heading("Sheets & Dialogs"),
                .table(headers: ["Shortcut", "Action"], rows: [
                    ["Return", "Submit / confirm"],
                    ["Escape", "Cancel / close"],
                ]),
            ]
        }
    }
}
