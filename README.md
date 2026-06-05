# Stash Mac

Native macOS app for storing, organizing, and retrieving links, files, snippets, images, and emails. A GUI frontend for the [stash](https://github.com/msjurset/gostash) CLI tool.

## Features

- **Browse Items** — Sidebar navigation with filters for all items, by type (links, snippets, files, images, emails), by tag, or by collection
- **Item Detail** — View title, URL, notes, tags, collections, file metadata, archive contents tree, and extracted text at a glance. Email bodies render as Markdown (bullets, headings, links) with Outlook SafeLinks unwrapped to their real destinations
- **Email Sender Display** — In list views, email items show the sender name on the second line (parsed from the `From:` header) instead of just the `#email` tag
- **Quick Search** — Press ⌘K for an instant search overlay with real-time results and keyboard navigation
- **Add Items** — Tabbed sheet for adding URLs, files (with file picker), or text snippets with optional title, tags, note, and collection. The File tab also has an "Or fetch files from a URL" row that hands off to the Fetch Files via URL picker
- **Fetch Files via URL** — File menu ▸ Fetch Files via URL… (⌘⇧U), or the button on a URL item's detail pane, or the right-click menu on URL list rows. Discover image / file links on a page, pick the ones to keep, optionally cross-link them with the source page, and stash each as its own item. Same `stash fetch-url` pipeline the Chrome extension uses
- **Import Bookmarks** — File ▸ Import Bookmarks… opens a three-phase wizard: pick a source (Safari, Chrome, Edge, Brave, Arc, Vivaldi, Opera, Chromium, Firefox, Pocket, Pinterest CSV, Raindrop.io CSV, or generic Netscape HTML), preview the full bookmark tree with per-row checkboxes + inline tag pills + a `DUPLICATE` badge for URLs already in your stash, then commit the curated subset. Folder breadcrumb becomes the default tag set; Safari needs Full Disk Access (the sheet surfaces a one-click "Open System Settings" + "Reveal stash CLI in Finder" shortcut)
- **Import Browser History** — File ▸ Import Browser History… reads the local history database for any supported browser, bounded by an adjustable look-back slider (default 15 days). Items group into Today / Yesterday / Past 7 days / Past 30 days / Older buckets with the same per-row picker, tag pills, and dedup badge as the bookmarks importer. Safe to run while the browser is open
- **Drag and Drop** — Drop files directly onto the window to stash them
- **System Services** — Right-click "Stash Selection" in any app to stash highlighted text or selected files (Finder, Mail, browsers, etc.). Use **"Read Later"** or **"Watch Later"** to stash directly into your triage queue. Bind keyboard shortcuts in System Settings → Keyboard → Keyboard Shortcuts → Services for one-key capture.
- **Triage Workflow** — Driven by `read-later` and `watch-later` tags. See the [Triage Workflow Guide](docs/triage-workflow.md) for details.
- **Auto-Refresh on Capture** — Drops via System Services, the menubar quick-stash, or the clipboard watcher refresh the main window automatically — no manual reload
- **Edit Items** — Modify title, notes, extracted text, and tags; add or remove tags with visual feedback; update collection assignment. Double-click the title to edit in place; double-click the Notes or Extracted Text block to open a 780×520 popout editor that saves on click-away
- **Export** — Right-click on selected items (single or multi), a sidebar tag, or a sidebar collection to export to a `.zip` archive. File ▸ Import Archive… (⌘⇧I) round-trips them back into any Stash install
- **Tag Management** — View all tags in the sidebar; right-click to rename
- **Collections** — Create, browse, and delete collections for grouping related items
- **Type Filtering** — Filter the item list by type, tag, or collection from the sidebar or during search
- **Open Items** — Open any stashed item with the system default application
- **Keyboard Shortcuts** — ⌘N add, ⌘K search, ⌘R reload from CLI (picks up external changes), ⌘⇧U Fetch Files via URL, ⌘⇧I Import Archive, ⌘? toggle X-Ray mode
- **Tag Graph** — Force-directed graph of tag co-occurrence with cursor-anchored pinch-zoom (zoom toward where the pointer is, even after panning)
- **Capture Rules** — Sidebar "Rules" entry plus `stash rules` CLI for declarative tagging, retitling, note-stamping, notifying, linking, or skipping items as they're stashed. Match by domain, MIME, sender, content regex (with named captures); compose action chains; templates with `{{.Title}}` `{{.Sender}}` `{{.Captures.X}}` etc. Rules live at `~/.stash/rules.yaml`
- **Vim Mode & Slash Commands** — Opt-in Vim keybindings for every multi-line text field (Notes, Extracted Text, AI Prompt). Type `/vim` in any editor to toggle. Support for slash commands like `/uc` (uppercase), `/trim`, `/sort`, `/unique`, `/date`, and AI-powered `/fix` (spelling), `/sum` (summary), and `/tags` (suggest tags).
- **Advanced Search & Regex** — Search query supports `collection:name` to filter by collection, `tag:name` for tags, and operators: `!tag:name` (not tagged), `-tag:name` (exclude), and `^tag:name` (exact tag match). Press the `*` toggle or type `//` in any search field to switch to **Regex Mode** (RE2 syntax matching against title, notes, URL, and extracted text). Global commands like `/today`, `/yesterday`, `/untagged`, and `/favorites` available directly from the search bar.
- **Identify with AI** — Right-click any image item → Identify with <provider> to send the photo to a pluggable AI backend (Google Gemini or Anthropic Claude) and slot the returned title/notes back into the item. Includes OCR transcript support (Gemini), API key caching via 1Password CLI, and transient error retry logic.
- **Video Transcription** — High-quality transcription for video captures using Gemini Multimodal analysis (full video) or a Lite mode (audio extraction via AVFoundation) for 90% cost savings. Includes cost estimation warnings for long videos and automatic transcript section visibility.
- **AI Cost Tracking** — View token usage and cost forecasts for Gemini Identify calls in Settings → AI. Includes 30-day projections and aggregate spend across both this Mac and the `stash serve` daemon.
- **Favorite Tag** — Designate a specific tag (usually `fav` or `favorite`) as the "Favorite" tag in `Models/FavoriteTag.swift`; items carrying it show a yellow star indicator in list views.
- **Thumbnails** — Per-item thumbnail tile in the detail view and a 28pt preview in list rows. Auto-generated for files via QuickLook (PDF, video frame, audio album art, code/Office/iWork previews) on capture. URL items use the CLI's HTML scraper with a WKWebView render fallback for JS-heavy sites like Amazon. Manual override: drop an image file onto the tile, or paste a remote image URL / local path via the "Set from…" menu. Stored at `~/.stash/files/thumbnails/<id>.jpg`
- **Location** — Image items auto-fill a structured location field from JPEG EXIF GPS tags on capture, or via the Android Location API on mobile. The detail pane shows a Location row with the coordinates, source badge (exif / capture / manual), and an Open in Maps link. Edit lat/lon in the Edit dialog, or run `stash backfill-locations --all` to retroactively populate every existing image
- **Help System** — Interactive X-Ray Mode (⌘?) spotlights key UI elements with floating pointers for instant onboarding. Full help content with topics for every major feature is available under the Help menu (Stash Help).

## Requirements

- macOS 15.0 (Sequoia) or later
- [stash](https://github.com/msjurset/gostash) CLI installed and available in your `PATH`

## Install

### Homebrew

```sh
brew install --cask msjurset/tap/stash-mac
```

This also installs the `stash` CLI if you don't already have it.

### From source

```sh
make deploy
```

This builds the app, creates the `.app` bundle with icon, and installs to `/Applications/Stash.app`.

## Build

```
make build           # Compile release binary
make bundle          # Build + create .app bundle
make test            # Run tests
make phantom-check   # Launch app with STASH_PHANTOM_CHECK=1, exit non-zero
                     # if the phantom autofill / inline-prediction popup is
                     # observed in the window tree. Defaults to a 30s window
                     # (set CHECK_SECONDS=N to extend); click around during
                     # the run to exercise focus paths.
```

## Architecture

The Mac app is a **frontend** — it does not reimplement the stash storage engine. All operations are delegated to the `stash` CLI binary via `Process`:

- `stash list --json` for browsing with type/tag/collection filters
- `stash search --json <query>` for full-text search
- `stash add --json` for storing URLs, files, and snippets (stdin)
- `stash edit --json` for updating title, notes, extracted text, tags, and collection
- `stash delete --json`, `stash open` for item management
- `stash tag list/rename`, `stash collection list/create/delete` for organization

The shared contract between the app and CLI is:

- All data managed by the `stash` CLI's internal store
- JSON output mode (`--json`) for structured communication
- The `stash` binary in `$PATH`, `~/.local/bin/`, `~/go/bin/`, or `/opt/homebrew/bin/`

## Project Structure

```
Sources/StashMac/
  Models/           StashItem, ItemType, Tag, Collection, NavigationItem
  Services/         StashCLI (Process bridge), StashStore (state management)
  Views/
    Sidebar/        Navigation sidebar with type/tag/collection filters
    List/           Item list with search, context menus, loading states
    Detail/         Item detail view with metadata, archive tree, and extracted text
    Sheets/         Add item, edit item, add collection sheets
    Search/         Quick search overlay (⌘K)
    Help/           Help system with structured content
```

## License

MIT
