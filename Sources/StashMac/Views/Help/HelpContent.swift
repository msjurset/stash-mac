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
                .paragraph("Results are color-coded by severity. URL checks may take a moment as each link is tested."),
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
