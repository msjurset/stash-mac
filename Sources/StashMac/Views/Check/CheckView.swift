import SwiftUI
import AppKit
import Quartz

struct CheckView: View {
    @Environment(StashStore.self) private var store

    @State private var pendingDeleteIDs: [String] = []
    @State private var selectedIssueIDs: Set<String> = []
    @State private var selectedOrphanPaths: Set<String> = []
    @State private var lastClickedOrphanPath: String?
    @State private var pendingDeleteOrphanPaths: [String] = []
    @State private var urlEdit: URLEditTarget?

    @FocusState private var isListFocused: Bool

    var body: some View {
        ZStack {
            // Global key monitor that intercepts navigation and deletion
            // keys even when the QuickLook preview panel has focus.
            HealthCheckKeyMonitor(
                onMove: { delta in 
                    isListFocused = true
                    moveSelection(delta: delta) 
                },
                onDelete: { 
                    isListFocused = true
                    triggerDelete() 
                },
                onTogglePreview: { 
                    isListFocused = true
                    togglePreview() 
                },
                onDismissPreview: {
                    if QLPreviewPanel.shared()?.isVisible == true {
                        QLPreviewPanel.shared()?.orderOut(nil)
                        isListFocused = true
                    }
                }
            )
            .frame(width: 0, height: 0)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if store.isCheckRunning {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
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
                            Button("Run Check") { store.runCheck() }
                                .buttonStyle(.borderedProminent)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 40)
                    }
                }
                .padding()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom) { bulkActionBar }
        .toolbar {
            ToolbarItem {
                Button { store.runCheck() } label: {
                    Label("Run Check", systemImage: "arrow.clockwise")
                }
                .help("Run health check")
                .disabled(store.isCheckRunning)
            }
            ToolbarItem {
                ContextualHelpButton(topic: .statsAndCheck, isToolbarItem: true)
            }
        }
        .sheet(item: $urlEdit) { target in EditURLSheet(target: target) }
        .focused($isListFocused)
        .onAppear { isListFocused = true }
        .onTapGesture { isListFocused = true }
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
            Button("Cancel", role: .cancel) { pendingDeleteIDs = [] }
        } message: {
            Text("This permanently removes the item from your stash. To soft-delete (recoverable), use Archive instead.")
        }
        .confirmationDialog(
            confirmDeleteOrphansTitle,
            isPresented: Binding(
                get: { !pendingDeleteOrphanPaths.isEmpty },
                set: { if !$0 { pendingDeleteOrphanPaths = [] } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                store.deleteOrphanedFiles(relativePaths: pendingDeleteOrphanPaths)
                selectedOrphanPaths.subtract(pendingDeleteOrphanPaths)
                pendingDeleteOrphanPaths = []
            }
            Button("Cancel", role: .cancel) { pendingDeleteOrphanPaths = [] }
        } message: {
            Text("This permanently deletes the files from your storage. This cannot be undone.")
        }
    }

    private var confirmDeleteTitle: String {
        pendingDeleteIDs.count == 1 ? "Delete this item?" : "Delete \(pendingDeleteIDs.count) items?"
    }

    private var confirmDeleteOrphansTitle: String {
        pendingDeleteOrphanPaths.count == 1 ? "Delete this orphaned file?" : "Delete \(pendingDeleteOrphanPaths.count) orphaned files?"
    }

    private func triggerDelete() {
        if !selectedOrphanPaths.isEmpty {
            pendingDeleteOrphanPaths = Array(selectedOrphanPaths)
        } else if !selectedIssueIDs.isEmpty {
            pendingDeleteIDs = Array(selectedIssueIDs)
        } else if let focused = store.selectedItemID {
            pendingDeleteIDs = [focused]
        }
    }

    private func togglePreview() {
        if QLPreviewPanel.shared()?.isVisible == true {
            QLPreviewPanel.shared()?.orderOut(nil)
            return
        }
        
        if !selectedOrphanPaths.isEmpty {
            let paths = selectedOrphanPaths.sorted().map(absoluteOrphanPath)
            QuickLookPreviewer.shared.showPaths(paths: paths)
        } else if !selectedIssueIDs.isEmpty {
            let ids = Array(selectedIssueIDs).sorted()
            Task {
                var fetched: [StashItem] = []
                for id in ids {
                    if let existing = store.items.first(where: { $0.id == id }) {
                        fetched.append(existing)
                    } else if let item = try? await StashCLI.shared.getItem(id: id) {
                        fetched.append(item)
                    }
                }
                await MainActor.run { QuickLookPreviewer.shared.show(items: fetched) }
            }
        } else if let focusedID = store.selectedItemID {
            Task {
                if let existing = store.items.first(where: { $0.id == focusedID }) {
                    await MainActor.run { QuickLookPreviewer.shared.show(items: [existing]) }
                } else if let item = try? await StashCLI.shared.getItem(id: focusedID) {
                    await MainActor.run { QuickLookPreviewer.shared.show(items: [item]) }
                }
            }
        }
    }

    @ViewBuilder
    private func resultView(_ result: CheckResult, running: Bool) -> some View {
        if result.isEmpty {
            if !running {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").font(.largeTitle).foregroundStyle(.green)
                    Text("No issues found").font(.headline)
                    Text("Your stash is healthy.").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 40)
            }
        } else {
            Text("\(result.totalIssues) issue(s) found\(running ? " so far…" : "")").font(.headline)
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
                Label("\(title) (\(items.count))", systemImage: icon).font(.subheadline.bold()).foregroundStyle(color)
                copyButton {
                    items.map { issue in
                        if isURL, let detail = issue.detail { return "\(issue.title)\t\(detail)" }
                        return issue.title
                    }.joined(separator: "\n")
                }
            }
            ForEach(items) { issueRow($0, isURL: isURL) }
        }
    }

    @ViewBuilder
    private func copyButton(_ payload: @escaping () -> String) -> some View {
        Button {
            let text = payload()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        } label: {
            Image(systemName: "doc.on.clipboard").font(.caption).foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func issueRow(_ issue: CheckIssue, isURL: Bool = false) -> some View {
        let isInBulk = selectedIssueIDs.contains(issue.id)
        let isFocused = store.selectedItemID == issue.id
        let bg: Color = isInBulk ? Color.accentColor.opacity(0.28) : (isFocused ? Color.accentColor.opacity(0.15) : Color.clear)
        HStack(spacing: 6) {
            Text(issue.title).lineLimit(1)
            Spacer()
            if let detail = issue.detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            if isURL {
                Button { store.recheckBrokenURL(id: issue.id) } label: { Image(systemName: "arrow.clockwise").font(.caption) }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 3).padding(.horizontal, 8)
        .background(bg, in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { store.openItem(id: issue.id) }
        .onTapGesture { issueRowTap(issue.id) }
        .contextMenu { issueContextMenu(issue, isURL: isURL) }
    }

    private func issueRowTap(_ id: String) {
        if NSEvent.modifierFlags.contains(.command) {
            if selectedIssueIDs.contains(id) { selectedIssueIDs.remove(id) } else { selectedIssueIDs.insert(id) }
        } else {
            selectedIssueIDs = []
            store.selectItemByID(id)
        }
        isListFocused = true
    }

    @ViewBuilder
    private func issueContextMenu(_ issue: CheckIssue, isURL: Bool) -> some View {
        let targets = selectedIssueIDs.contains(issue.id) ? Array(selectedIssueIDs) : [issue.id]
        if targets.count == 1 {
            Button("Show in All Items") { store.selectedItemID = issue.id; store.applyNavigation(.allItems) }
            Button("Open") { store.openItem(id: issue.id) }
        }
        if isURL && targets.count == 1 {
            Divider()
            Button("Edit URL…") { urlEdit = URLEditTarget(id: issue.id, title: issue.title) }
            Button("Refetch URL Content") { store.refetchURLContent(id: issue.id) }
            Button("Copy URL") { store.copyItemField(id: issue.id, field: "url") }
            Button("Ask Google") { askGoogle(about: issue.id) }
        }
        Divider()
        Button(targets.count > 1 ? "Copy IDs" : "Copy ID") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(targets.joined(separator: "\n"), forType: .string)
        }
        Divider()
        Button("Archive") { store.archiveItems(ids: targets) }
        Button("Delete…", role: .destructive) { pendingDeleteIDs = targets }
    }

    @ViewBuilder
    private func orphanedSection(_ files: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label("Orphaned Files (\(files.count))", systemImage: "doc.badge.gearshape").font(.subheadline.bold()).foregroundStyle(.yellow)
                copyButton { files.joined(separator: "\n") }
            }
            ForEach(files, id: \.self) { orphanedRow($0) }
        }
    }

    @ViewBuilder
    private func orphanedRow(_ file: String) -> some View {
        let isSelected = selectedOrphanPaths.contains(file)
        HStack(spacing: 8) {
            Image(systemName: iconForFile(file)).foregroundStyle(.secondary).frame(width: 16)
            Text(file).font(.callout.monospaced())
        }
        .padding(.vertical, 3).padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.28) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { openOrphanFile(file) }
        .onTapGesture { orphanRowTap(file) }
        .contextMenu { orphanContextMenu(file) }
    }

    @ViewBuilder
    private func orphanContextMenu(_ file: String) -> some View {
        let targets = selectedOrphanPaths.contains(file) ? Array(selectedOrphanPaths) : [file]
        Button("Reveal in Finder") {
            let urls = targets.map { URL(fileURLWithPath: absoluteOrphanPath($0)) }
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
        Button(targets.count > 1 ? "Copy Paths" : "Copy Path") {
            let joined = targets.sorted().map(absoluteOrphanPath).joined(separator: "\n")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(joined, forType: .string)
        }
        Divider()
        Button(targets.count > 1 ? "Delete \(targets.count) Orphaned Files" : "Delete Orphaned File", role: .destructive) { pendingDeleteOrphanPaths = targets }
    }

    private func iconForFile(_ relativePath: String) -> String {
        let ext = (relativePath as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "tiff": return "photo"
        case "mp4", "mov", "m4v", "avi", "mkv": return "video"
        case "mp3", "m4a", "wav", "flac", "ogg": return "speaker.wave.2"
        case "pdf": return "doc.richtext"
        case "txt", "md", "markdown": return "doc.text"
        case "html", "htm": return "globe"
        case "zip", "gz", "tar": return "doc.zipper"
        default: return "doc"
        }
    }

    private func openOrphanFile(_ relative: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: absoluteOrphanPath(relative)))
    }

    private func orphanRowTap(_ file: String) {
        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.command) {
            if selectedOrphanPaths.contains(file) { selectedOrphanPaths.remove(file) } else { selectedOrphanPaths.insert(file) }
            lastClickedOrphanPath = file
        } else if modifiers.contains(.shift), let last = lastClickedOrphanPath, let orphans = store.checkResult?.orphanedFiles {
            if let startIdx = orphans.firstIndex(of: last), let endIdx = orphans.firstIndex(of: file) {
                let range = startIdx < endIdx ? startIdx...endIdx : endIdx...startIdx
                for i in range { selectedOrphanPaths.insert(orphans[i]) }
            }
        } else {
            if selectedOrphanPaths == [file] { selectedOrphanPaths = []; lastClickedOrphanPath = nil } else { selectedOrphanPaths = [file]; lastClickedOrphanPath = file }
        }
        isListFocused = true
    }

    private func moveSelection(delta: Int) {
        guard let result = store.checkResult else { return }
        var all: [String] = []
        if let broken = result.brokenUrls { all.append(contentsOf: broken.map(\.id)) }
        if let missing = result.missingFiles { all.append(contentsOf: missing.map(\.id)) }
        if let hashes = result.duplicateHashes { for group in hashes { all.append(contentsOf: group.items.map(\.id)) } }
        if let orphaned = result.orphanedFiles { all.append(contentsOf: orphaned) }
        guard !all.isEmpty else { return }
        let current: String?
        if !selectedOrphanPaths.isEmpty { current = lastClickedOrphanPath ?? selectedOrphanPaths.sorted().first }
        else if !selectedIssueIDs.isEmpty { current = Array(selectedIssueIDs).sorted().first }
        else { current = store.selectedItemID }
        let idx = current.flatMap { all.firstIndex(of: $0) } ?? (delta > 0 ? -1 : all.count)
        let nextIdx = max(0, min(idx + delta, all.count - 1))
        guard nextIdx != idx else { return }
        let next = all[nextIdx]
        if let orphaned = result.orphanedFiles, orphaned.contains(next) {
            selectedIssueIDs = []; selectedOrphanPaths = [next]; lastClickedOrphanPath = next; store.selectedItemID = nil
            QuickLookPreviewer.shared.refresh(paths: [absoluteOrphanPath(next)])
        } else {
            selectedOrphanPaths = []; lastClickedOrphanPath = nil; selectedIssueIDs = []; store.selectItemByID(next)
            if let item = store.items.first(where: { $0.id == next }) { QuickLookPreviewer.shared.refresh(items: [item]) }
            else { Task { if let fetched = try? await StashCLI.shared.getItem(id: next) { await MainActor.run { QuickLookPreviewer.shared.refresh(items: [fetched]) } } } }
        }
    }

    private func absoluteOrphanPath(_ relative: String) -> String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".stash").appendingPathComponent("files").appendingPathComponent(relative).path
    }

    private func askGoogle(about itemID: String) {
        if let item = store.items.first(where: { $0.id == itemID }), let url = item.url, !url.isEmpty { openGoogleSearch(forURL: url); return }
        Task { do { let item = try await StashCLI.shared.getItem(id: itemID)
            guard let url = item.url, !url.isEmpty else { return }
            await MainActor.run { openGoogleSearch(forURL: url) }
        } catch { } }
    }

    private func openGoogleSearch(forURL url: String) {
        var comps = URLComponents(string: "https://www.google.com/search")
        comps?.queryItems = [URLQueryItem(name: "q", value: "What happened to \(url)?")]
        if let searchURL = comps?.url { NSWorkspace.shared.open(searchURL) }
    }

    @ViewBuilder
    private func dupeItemRow(_ item: CheckIssue) -> some View {
        let isInBulk = selectedIssueIDs.contains(item.id)
        let isFocused = store.selectedItemID == item.id
        let bg: Color = isInBulk ? Color.accentColor.opacity(0.28) : (isFocused ? Color.accentColor.opacity(0.15) : Color.clear)
        HStack {
            Text(item.title).lineLimit(1)
            Spacer()
            Text(String(item.id.prefix(10))).font(.caption.monospaced()).foregroundStyle(.secondary)
        }
        .padding(.leading, 12).padding(.vertical, 2).padding(.trailing, 4)
        .background(bg, in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { store.openItem(id: item.id) }
        .onTapGesture { issueRowTap(item.id) }
        .contextMenu { issueContextMenu(item, isURL: false) }
    }

    @ViewBuilder
    private func dupeSection(_ groups: [DupeGroup]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label("Duplicate Content (\(groups.count) groups)", systemImage: "doc.on.doc").font(.subheadline.bold()).foregroundStyle(.purple)
                copyButton { groups.map { g in "Hash \(String(g.hash.prefix(16))):\n" + g.items.map { "  - \($0.title)" }.joined(separator: "\n") }.joined(separator: "\n\n") }
            }
            ForEach(groups) { g in
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hash: \(String(g.hash.prefix(16)))...").font(.caption.monospaced()).foregroundStyle(.secondary)
                    ForEach(g.items) { dupeItemRow($0) }
                }
                .padding(.vertical, 4).padding(.horizontal, 8)
            }
        }
    }

    @ViewBuilder
    private var bulkActionBar: some View {
        if !selectedIssueIDs.isEmpty {
            actionBar(count: selectedIssueIDs.count, noun: "item", actions: {
                Button("Archive") { store.archiveItems(ids: Array(selectedIssueIDs)); selectedIssueIDs = [] }
                Button("Delete", role: .destructive) { pendingDeleteIDs = Array(selectedIssueIDs) }
            }, onClear: { selectedIssueIDs = [] })
        } else if !selectedOrphanPaths.isEmpty {
            actionBar(count: selectedOrphanPaths.count, noun: "orphan file", actions: {
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting(selectedOrphanPaths.map { URL(fileURLWithPath: absoluteOrphanPath($0)) }) }
                Button("Copy Paths") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(selectedOrphanPaths.sorted().map(absoluteOrphanPath).joined(separator: "\n"), forType: .string) }
                Button("Delete", role: .destructive) { pendingDeleteOrphanPaths = Array(selectedOrphanPaths) }
            }, onClear: { selectedOrphanPaths = [] })
        }
    }

    @ViewBuilder
    private func actionBar<Actions: View>(count: Int, noun: String, @ViewBuilder actions: () -> Actions, onClear: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Text("\(count) \(noun)\(count == 1 ? "" : "s") selected").font(.callout).foregroundStyle(.secondary)
            Spacer(); actions(); Button("Clear", action: onClear)
        }
        .padding(.horizontal, 16).padding(.vertical, 10).background(.bar)
    }
}

private struct HealthCheckKeyMonitor: NSViewRepresentable {
    let onMove: (Int) -> Void
    let onDelete: () -> Void
    let onTogglePreview: () -> Void
    let onDismissPreview: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = MonitorView()
        view.onMove = onMove
        view.onDelete = onDelete
        view.onTogglePreview = onTogglePreview
        view.onDismissPreview = onDismissPreview
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}

    class MonitorView: NSView {
        var onMove: ((Int) -> Void)?
        var onDelete: (() -> Void)?
        var onTogglePreview: (() -> Void)?
        var onDismissPreview: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                let keyWindow = NSApplication.shared.keyWindow
                let qlVisible = QLPreviewPanel.shared()?.isVisible == true
                let isQLKey = qlVisible && keyWindow == QLPreviewPanel.shared()
                let isOurWindow = keyWindow == self.window
                
                // Intercept keys if our window is active OR if QL is active over our app.
                guard isOurWindow || isQLKey else { return event }

                // Don't intercept if a text field has focus (unless it's the QL panel itself)
                if !isQLKey, let responder = keyWindow?.firstResponder,
                   (responder is NSTextView || responder is NSTextField) {
                    return event
                }

                let keyCode = event.keyCode
                let char = event.charactersIgnoringModifiers?.lowercased() ?? ""

                switch keyCode {
                case 126, 125, 123, 124: // Arrows
                    let delta = (keyCode == 126 || keyCode == 123) ? -1 : 1
                    MainActor.assumeIsolated { self.onMove?(delta) }
                    return nil
                case 51, 117: // Delete
                    MainActor.assumeIsolated { self.onDelete?() }
                    return nil
                case 49: // Space
                    MainActor.assumeIsolated { self.onTogglePreview?() }
                    return nil
                case 53: // Escape
                    if qlVisible { MainActor.assumeIsolated { self.onDismissPreview?() }; return nil }
                default:
                    if char == "j" || char == "l" { MainActor.assumeIsolated { self.onMove?(1) }; return nil }
                    if char == "k" || char == "h" { MainActor.assumeIsolated { self.onMove?(-1) }; return nil }
                }
                return event
            }
        }
        override func removeFromSuperview() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            super.removeFromSuperview()
        }
    }
}

private struct URLEditTarget: Identifiable { let id: String; let title: String }
private struct EditURLSheet: View {
    @Environment(StashStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let target: URLEditTarget
    @State private var url: String = ""; @State private var loaded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit URL").font(.headline)
            Text(target.title).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            VStack(alignment: .leading, spacing: 4) {
                Text("URL").font(.caption).foregroundStyle(.secondary)
                FilterField(placeholder: "https://…", text: $url, autoFocus: true).padding(.horizontal, 8).padding(.vertical, 5).background(.quaternary.opacity(0.3)).clipShape(RoundedRectangle(cornerRadius: 5))
            }
            Text("Updates the item's URL in place.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer(); Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { let t = url.trimmingCharacters(in: .whitespaces); if !t.isEmpty { store.updateURL(id: target.id, url: t); dismiss() } }.keyboardShortcut(.defaultAction).disabled(url.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20).frame(width: 460)
        .task { if !loaded { if let item = store.items.first(where: { $0.id == target.id }), let u = item.url { url = u }; loaded = true } }
    }
}
