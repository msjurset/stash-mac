# Stash Mac

Native macOS app for storing, organizing, and retrieving links, files, snippets, images, and emails. A GUI frontend for the [stash](https://github.com/msjurset/gostash) CLI tool.

## Features

- **Browse Items** — Sidebar navigation with filters for all items, by type (links, snippets, files, images, emails), by tag, or by collection
- **Item Detail** — View title, URL, notes, tags, collections, file metadata, archive contents tree, and extracted text at a glance
- **Quick Search** — Press ⌘K for an instant search overlay with real-time results and keyboard navigation
- **Add Items** — Tabbed sheet for adding URLs, files (with file picker), or text snippets with optional title, tags, note, and collection
- **Drag and Drop** — Drop files directly onto the window to stash them
- **Edit Items** — Modify title, notes, extracted text, and tags; add or remove tags with visual feedback; update collection assignment
- **Tag Management** — View all tags in the sidebar; right-click to rename
- **Collections** — Create, browse, and delete collections for grouping related items
- **Type Filtering** — Filter the item list by type, tag, or collection from the sidebar or during search
- **Open Items** — Open any stashed item with the system default application
- **Keyboard Shortcuts** — ⌘N to add, ⌘K to search, ⌘? for help
- **Help System** — Menu bar Help (⌘?) with 9 topics + contextual ? button on detail, list, and add views

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
make build       # Compile release binary
make bundle      # Build + create .app bundle
make test        # Run tests
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
