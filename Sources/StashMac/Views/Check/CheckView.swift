import SwiftUI
import AppKit

struct CheckView: View {
    @Environment(StashStore.self) private var store

    /// Holds the item IDs the user just confirmed they want to delete.
    /// `.confirmationDialog` reads off this; setting it triggers the
    /// dialog. Cleared after the dialog dismisses.
    @State private var pendingDeleteIDs: [String] = []

    /// Multi-select for stash-item rows (broken URLs, missing files,
    /// dupe items). Cmd-click toggles; plain click selects only.
    /// Bulk actions in the bottom bar archive/delete the whole set.
    @State private var selectedIssueIDs: Set<String> = []

    /// Multi-select for orphaned file rows. Kept separate from item
    /// rows because their actions (Reveal in Finder, Copy Paths) are
    /// file-system scoped — different bar, different verbs.
    @State private var selectedOrphanPaths: Set<String> = []

    /// Drives the per-row URL-edit sheet. Holds the (id, currentURL,
    /// title) of the row being edited; nil = sheet closed.
    @State private var urlEdit: URLEditTarget?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if store.isCheckRunning {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Running checks — results appear as issues are found…")
                            .foregroundStyle(.secondary)
                    }
                }

                if let result = store.checkResult {
                    resultView(result, running: store.isCheckRunning)
                } else if !store.isCheckRunning {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.shield")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("Run a health check on your stash")
                            .foregroundStyle(.secondary)
                        Button("Run Check") {
                            store.runCheck()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 40)
                }
            }
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom) {
            bulkActionBar
        }
        .toolbar {
            ToolbarItem {
                Button {
                    store.runCheck()
                } label: {
                    Label("Run Check", systemImage: "arrow.clockwise")
                }
                .help("Run health check")
                .disabled(store.isCheckRunning)
            }
        }
        .sheet(item: $urlEdit) { target in
            EditURLSheet(target: target)
        }
        .confirmationDialog(
            confirmDeleteTitle,
            isPresented: Binding(
                get: { !pendingDeleteIDs.isEmpty },
                set: { if !$0 { pendingDeleteIDs = [] } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                store.deleteItems(ids: pendingDeleteIDs)
                pendingDeleteIDs = []
                selectedIssueIDs = []
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteIDs = []
            }
        } message: {
            Text("This permanently removes the item from your stash. To soft-delete (recoverable), use Archive instead.")
        }
    }

    private var confirmDeleteTitle: String {
        pendingDeleteIDs.count == 1
            ? "Delete this item?"
            : "Delete \(pendingDeleteIDs.count) items?"
    }

    @ViewBuilder
    private func resultView(_ result: CheckResult, running: Bool) -> some View {
        if result.isEmpty {
            if !running {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.green)
                    Text("No issues found")
                        .font(.headline)
                    Text("Your stash is healthy.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 40)
            }
        } else {
            Text("\(result.totalIssues) issue(s) found\(running ? " so far…" : "")")
                .font(.headline)

            if let broken = result.brokenUrls, !broken.isEmpty {
                issueSection("Broken URLs", icon: "link.badge.plus", color: .red, items: broken, isURL: true)
            }

            if let missing = result.missingFiles, !missing.isEmpty {
                issueSection("Missing Files", icon: "doc.badge.ellipsis", color: .orange, items: missing, isURL: false)
            }

            if let orphaned = result.orphanedFiles, !orphaned.isEmpty {
                orphanedSection(orphaned)
            }

            if let dupes = result.duplicateHashes, !dupes.isEmpty {
                dupeSection(dupes)
            }
        }
    }

    @ViewBuilder
    private func issueSection(_ title: String, icon: String, color: Color, items: [CheckIssue], isURL: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label("\(title) (\(items.count))", systemImage: icon)
                    .font(.subheadline.bold())
                    .foregroundStyle(color)
                copyButton {
                    items.map { issue in
                        if isURL, let detail = issue.detail {
                            return "\(issue.title)\t\(detail)"
                        }
                        return issue.title
                    }.joined(separator: "\n")
                }
            }

            ForEach(items) { issue in
                issueRow(issue, isURL: isURL)
            }
        }
    }

    /// Small clipboard-icon button — copies the section's contents
    /// (one entry per line) so the user can paste into another tool
    /// (e.g., an LLM chat) and bulk-process. Shows a momentary
    /// checkmark on copy for feedback.
    @ViewBuilder
    private func copyButton(_ payload: @escaping () -> String) -> some View {
        Button {
            let text = payload()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        } label: {
            Image(systemName: "doc.on.clipboard")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Copy this section's contents to the clipboard")
    }

    @ViewBuilder
    private func issueRow(_ issue: CheckIssue, isURL: Bool = false) -> some View {
        let isInBulk = selectedIssueIDs.contains(issue.id)
        let isFocused = store.selectedItemID == issue.id
        // Bulk-selected highlight wins visually over the
        // detail-pane focus highlight; bulk is the active scope when
        // the user is multi-selecting.
        let bg: Color = isInBulk
            ? Color.accentColor.opacity(0.28)
            : (isFocused ? Color.accentColor.opacity(0.15) : Color.clear)
        HStack(spacing: 6) {
            Text(issue.title)
                .lineLimit(1)
            Spacer()
            if let detail = issue.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if isURL {
                // Per-row refresh — re-checks just this URL via the
                // single-row recheck path. Useful right after a URL
                // edit (or after fixing the underlying server) when
                // the user wants to verify without re-running the
                // whole health check.
                Button {
                    store.recheckBrokenURL(id: issue.id)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Recheck this URL")
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
        .background(bg, in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture {
            issueRowTap(issue.id)
        }
        .contextMenu {
            issueContextMenu(issue, isURL: isURL)
        }
    }

    /// Plain click clears the bulk selection and focuses one row.
    /// Cmd-click toggles the row in/out of the bulk set without
    /// touching the focus state. Detection is via `NSEvent.modifier
    /// Flags` because SwiftUI's onTapGesture doesn't expose modifier
    /// keys directly.
    private func issueRowTap(_ id: String) {
        if NSEvent.modifierFlags.contains(.command) {
            if selectedIssueIDs.contains(id) {
                selectedIssueIDs.remove(id)
            } else {
                selectedIssueIDs.insert(id)
            }
        } else {
            selectedIssueIDs = []
            store.selectItemByID(id)
        }
    }

    /// Shared context menu for any item-row in the Health Check view.
    /// Branches on `isURL` to expose URL-specific actions (Refetch,
    /// Copy URL) only where they make sense.
    @ViewBuilder
    private func issueContextMenu(_ issue: CheckIssue, isURL: Bool) -> some View {
        Button("Show in All Items") {
            store.selectedItemID = issue.id
            store.applyNavigation(.allItems)
        }
        Button("Open") {
            store.openItem(id: issue.id)
        }
        if isURL {
            Divider()
            Button("Edit URL…") {
                urlEdit = URLEditTarget(id: issue.id, title: issue.title)
            }
            Button("Refetch URL Content") {
                store.refetchURLContent(id: issue.id)
            }
            Button("Copy URL") {
                store.copyItemField(id: issue.id, field: "url")
            }
            Button("Ask Google") {
                askGoogle(about: issue.id)
            }
        }

        Divider()
        Button("Copy ID") {
            store.copyItemField(id: issue.id, field: "id")
        }

        Divider()
        Button("Archive") {
            store.archiveItems(ids: [issue.id])
        }
        Button("Delete…", role: .destructive) {
            pendingDeleteIDs = [issue.id]
        }
    }

    @ViewBuilder
    private func orphanedSection(_ files: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label("Orphaned Files (\(files.count))", systemImage: "doc.badge.gearshape")
                    .font(.subheadline.bold())
                    .foregroundStyle(.yellow)
                copyButton { files.joined(separator: "\n") }
            }

            ForEach(files, id: \.self) { file in
                orphanedRow(file)
            }
        }
    }

    @ViewBuilder
    private func orphanedRow(_ file: String) -> some View {
        let isSelected = selectedOrphanPaths.contains(file)
        Text(file)
            .font(.callout.monospaced())
            .padding(.vertical, 3)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor.opacity(0.28) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .onTapGesture {
                orphanRowTap(file)
            }
            .contextMenu {
                Button("Reveal in Finder") {
                    revealOrphanInFinder(file)
                }
                Button("Copy Path") {
                    let abs = absoluteOrphanPath(file)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(abs, forType: .string)
                }
            }
    }

    private func orphanRowTap(_ file: String) {
        if NSEvent.modifierFlags.contains(.command) {
            if selectedOrphanPaths.contains(file) {
                selectedOrphanPaths.remove(file)
            } else {
                selectedOrphanPaths.insert(file)
            }
        } else {
            // Plain click toggles single-select for orphan files
            // (no detail pane equivalent; just visual selection).
            if selectedOrphanPaths == [file] {
                selectedOrphanPaths = []
            } else {
                selectedOrphanPaths = [file]
            }
        }
    }

    /// Resolve an orphan-file relative path (e.g. "49/49a79…txt")
    /// against the default filestore root (~/.stash/files). Returns
    /// the absolute path string.
    private func absoluteOrphanPath(_ relative: String) -> String {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".stash")
            .appendingPathComponent("files")
            .appendingPathComponent(relative)
        return root.path
    }

    private func revealOrphanInFinder(_ relative: String) {
        let url = URL(fileURLWithPath: absoluteOrphanPath(relative))
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Open a Google search asking what happened to the broken URL.
    /// Mirrors the manual workflow most users fall back to ("paste
    /// the dead URL into Google to find the new home"). Falls back
    /// to a CLI fetch when the item isn't in the currently-loaded
    /// list — Health Check can list items from any view scope, so
    /// `store.items` isn't a reliable lookup table here.
    private func askGoogle(about itemID: String) {
        if let item = store.items.first(where: { $0.id == itemID }),
           let urlString = item.url, !urlString.isEmpty {
            openGoogleSearch(forURL: urlString)
            return
        }
        Task {
            do {
                let item = try await StashCLI.shared.getItem(id: itemID)
                guard let urlString = item.url, !urlString.isEmpty else { return }
                await MainActor.run { openGoogleSearch(forURL: urlString) }
            } catch {
                // Silent failure — user just sees nothing happen, same
                // as before. Logging would be noisy for an opportunistic
                // helper.
            }
        }
    }

    private func openGoogleSearch(forURL urlString: String) {
        var comps = URLComponents(string: "https://www.google.com/search")
        comps?.queryItems = [
            URLQueryItem(name: "q", value: "What happened to \(urlString)?")
        ]
        if let searchURL = comps?.url {
            NSWorkspace.shared.open(searchURL)
        }
    }

    @ViewBuilder
    private func dupeItemRow(_ item: CheckIssue) -> some View {
        let isInBulk = selectedIssueIDs.contains(item.id)
        let isFocused = store.selectedItemID == item.id
        let bg: Color = isInBulk
            ? Color.accentColor.opacity(0.28)
            : (isFocused ? Color.accentColor.opacity(0.15) : Color.clear)
        HStack {
            Text(item.title)
                .lineLimit(1)
            Spacer()
            Text(String(item.id.prefix(10)))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 12)
        .padding(.vertical, 2)
        .padding(.trailing, 4)
        .background(bg, in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture {
            issueRowTap(item.id)
        }
        .contextMenu {
            // Same actions as broken-URL / missing-file rows; the
            // dupe section's items are still real stash items, so
            // all the per-item operations apply equally. isURL=false
            // because we don't know the type at this layer.
            issueContextMenu(item, isURL: false)
        }
    }

    @ViewBuilder
    private func dupeSection(_ groups: [DupeGroup]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label("Duplicate Content (\(groups.count) groups)", systemImage: "doc.on.doc")
                    .font(.subheadline.bold())
                    .foregroundStyle(.purple)
                copyButton {
                    groups.map { group in
                        let header = "Hash \(String(group.hash.prefix(16))):"
                        let lines = group.items.map { "  - \($0.title)" }
                        return ([header] + lines).joined(separator: "\n")
                    }.joined(separator: "\n\n")
                }
            }

            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hash: \(String(group.hash.prefix(16)))...")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    ForEach(group.items) { item in
                        dupeItemRow(item)
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
            }
        }
    }

    // MARK: - Bulk action bar

    /// Bottom-pinned action bar. Shows up only when there's a
    /// selection in either of the two scopes. If both kinds are
    /// selected (item rows + orphan files), we surface the item-row
    /// actions — those are the destructive ones the user is most
    /// likely thinking about. They can clear and re-pick.
    @ViewBuilder
    private var bulkActionBar: some View {
        if !selectedIssueIDs.isEmpty {
            actionBar(
                count: selectedIssueIDs.count,
                noun: "item",
                actions: {
                    Button("Archive") {
                        store.archiveItems(ids: Array(selectedIssueIDs))
                        selectedIssueIDs = []
                    }
                    Button("Delete…", role: .destructive) {
                        // The confirmationDialog reads off
                        // pendingDeleteIDs; clearing the selection
                        // happens after the dialog's Delete button
                        // fires (see the dialog handler).
                        pendingDeleteIDs = Array(selectedIssueIDs)
                    }
                },
                onClear: { selectedIssueIDs = [] }
            )
        } else if !selectedOrphanPaths.isEmpty {
            actionBar(
                count: selectedOrphanPaths.count,
                noun: "orphan file",
                actions: {
                    Button("Reveal in Finder") {
                        let urls = selectedOrphanPaths.map {
                            URL(fileURLWithPath: absoluteOrphanPath($0))
                        }
                        NSWorkspace.shared.activateFileViewerSelecting(urls)
                    }
                    Button("Copy Paths") {
                        let joined = selectedOrphanPaths
                            .sorted()
                            .map(absoluteOrphanPath)
                            .joined(separator: "\n")
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(joined, forType: .string)
                    }
                },
                onClear: { selectedOrphanPaths = [] }
            )
        }
    }

    @ViewBuilder
    private func actionBar<Actions: View>(
        count: Int,
        noun: String,
        @ViewBuilder actions: () -> Actions,
        onClear: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Text("\(count) \(noun)\(count == 1 ? "" : "s") selected")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            actions()
            Button("Clear", action: onClear)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

/// Identifies which row's URL the user is editing. The struct's id
/// is the same string as the item id so SwiftUI's `.sheet(item:)`
/// re-presents cleanly when the user opens "Edit URL…" on a
/// different row.
struct URLEditTarget: Identifiable {
    let id: String
    let title: String
}

/// Focused single-field sheet for fixing a dead link. Shown from the
/// Health Check broken-URLs context menu. Pre-populates the field
/// with the item's current URL fetched on open; saves via
/// `store.updateURL(id:url:)` which also re-runs the active health
/// check so the broken row clears (or recurs) immediately.
struct EditURLSheet: View {
    @Environment(StashStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let target: URLEditTarget
    @State private var url: String = ""
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit URL")
                .font(.headline)
            Text(target.title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            VStack(alignment: .leading, spacing: 4) {
                Text("URL")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                FilterField(
                    placeholder: "https://…",
                    text: $url,
                    autoFocus: true
                )
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.quaternary.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }

            Text("Updates the item's URL in place. The active health check re-runs on save so this row clears if the new URL responds.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    let trimmed = url.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    store.updateURL(id: target.id, url: trimmed)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(url.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
        .task {
            // Fetch current URL on open so the field starts
            // pre-filled. We rely on the items list having been
            // loaded already (the Health Check view's parent loads
            // it on navigation); if not present, the field stays
            // empty and the user types from scratch.
            if !loaded {
                if let item = store.items.first(where: { $0.id == target.id }),
                   let u = item.url {
                    url = u
                }
                loaded = true
            }
        }
    }
}
