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

enum HelpTopic: String, CaseIterable, Identifiable {
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
                .heading("Quick Search"),
                .paragraph("Press ⌘K to open the quick search overlay. Results update in real time as you type. Click a result or press Return to jump to it."),
                .heading("List Filter"),
                .paragraph("The search field at the top of the item list filters items within the current sidebar selection. Press Return to search, or clear the field to show all items."),
                .heading("Combining Filters"),
                .paragraph("Select a type, tag, or collection in the sidebar first, then use the list search to narrow further. For example, select URLs in the sidebar, then search for \"api\" to find only URL items matching that term."),
            ]

        case .itemDetail:
            return [
                .paragraph("Select an item to view its full details in the right pane."),
                .heading("Sections"),
                .table(headers: ["Section", "Description"], rows: [
                    ["Header", "Type icon, title, and short ID"],
                    ["Player", "Inline AVKit player for audio/video files and direct-stream URLs (video has fullscreen toggle)"],
                    ["Thumbnail", "128pt preview tile. Drop an image to override; menu offers Generate, Set from URL/file, and Clear"],
                    ["URL", "Clickable link (for URL items)"],
                    ["Notes", "Your annotation text"],
                    ["Tags", "Tag capsules with # prefix"],
                    ["Collections", "Folder labels for assigned collections"],
                    ["File Info", "MIME type, file size, and source path"],
                    ["Archive Contents", "Interactive tree view of tar.gz and zip archive contents"],
                    ["Extracted Text", "Content extracted from links/files (collapsible)"],
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
                .paragraph("Click any issue row to load that item in the detail pane on the right. Right-click for options to open the item or jump to it in All Items."),
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
            ]

        case .keyboard:
            return [
                .heading("App Shortcuts"),
                .table(headers: ["Shortcut", "Action"], rows: [
                    ["⌘N", "Add new item"],
                    ["⌘K", "Quick search"],
                    ["⌘?", "Open help"],
                ]),
                .heading("Sheets & Dialogs"),
                .table(headers: ["Shortcut", "Action"], rows: [
                    ["Return", "Submit / confirm"],
                    ["Escape", "Cancel / close"],
                ]),
                .heading("Item List"),
                .table(headers: ["Shortcut", "Action"], rows: [
                    ["Return", "Search with current query"],
                    ["Right-click", "Open, Edit, or Delete an item"],
                ]),
            ]
        }
    }
}
