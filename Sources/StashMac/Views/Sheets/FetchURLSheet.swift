import SwiftUI
import AppKit
import ImageIO

/// File menu → "Fetch Files via URL…" sheet. Mirrors the Chrome
/// extension's picker for a desktop-only workflow: paste a URL,
/// discover image / file candidates on the page, pick the ones to
/// stash, optionally cross-link them with the source page.
///
/// Also automatically detects structured recipe data on the page
/// so the user can stash the clean recipe alongside (or instead of)
/// the page's images.
///
/// `initialURL` pre-populates the field and auto-runs Discover —
/// used by the detail-pane button on URL items, the list right-
/// click menu on URL items, and the Add Item ▸ File tab's
/// "fetch from URL" row.
struct FetchURLSheet: View {
    @Environment(StashStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var initialURL: String? = nil

    @State private var url: String = ""
    @State private var didAutoDiscover: Bool = false
    @State private var allLinks: Bool = false
    @State private var phase: Phase = .empty
    @State private var pageURL: String = ""
    @State private var pageTitle: String?
    @State private var candidates: [StashCLI.FetchURLCandidate] = []
    @State private var picked: Set<String> = []
    @State private var directURL: String?
    @State private var directMIME: String?
    @State private var directSize: Int64 = 0
    @State private var directTitle: String?

    @State private var discoveredRecipe: RecipeData?
    @State private var includeRecipe: Bool = true
    @State private var stashedRecipeItem: StashItem?

    /// ID of the row whose thumbnail popover is currently open.
    /// Single-id state so clicking thumb B atomically dismisses A's popover.
    @State private var activePopoverID: String?

    @State private var collection: String = ""
    @State private var extraTags: String = ""
    @State private var linkSourceTogether: Bool = true
    @State private var cliqueLinks: Bool = false
    @State private var error: String?

    enum Phase {
        case empty           // no URL discovered yet
        case discovering     // fetching list
        case page            // page result with candidates list
        case direct          // direct-file URL (no list, just one file)
        case stashing        // executing pick
        case done            // pick succeeded; show summary
    }

    @State private var pickSummary: StashCLI.FetchURLPickResult?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            urlField

            Divider()

            switch phase {
            case .empty:
                Text("Enter a URL above and click Discover to scan the page for stashable images, files, and recipes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .discovering:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Discovering candidates…").font(.callout)
                }
            case .page:
                pageBody
            case .direct:
                directBody
            case .stashing:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Stashing…").font(.callout)
                }
            case .done:
                doneBody
            }

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer()

            footerButtons
        }
        .padding(20)
        .frame(width: 720, height: 620)
        .onAppear {
            if let initial = initialURL, !initial.isEmpty, !didAutoDiscover {
                url = initial
                didAutoDiscover = true
                // Defer one runloop tick so the field renders with
                // the pre-populated value before Discover replaces
                // the empty state with the loading indicator.
                DispatchQueue.main.async { runDiscover() }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "tray.and.arrow.down")
                .font(.title3)
                .foregroundStyle(.tint)
            Text("Fetch Files via URL")
                .font(.headline)
            Spacer()
        }
    }

    // MARK: - URL row

    private var urlField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Page or file URL")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                FilterField(
                    placeholder: "https://example.com/article",
                    text: $url
                )
                Toggle("All links", isOn: $allLinks)
                    .help("Also include hyperlinks (not just images) in the candidate list.")
                Button("Discover") { runDiscover() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(url.trimmingCharacters(in: .whitespaces).isEmpty || phase == .discovering)
            }
        }
    }

    // MARK: - Page result

    private var pageBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let pageTitle, !pageTitle.isEmpty {
                Text(pageTitle)
                    .font(.callout)
                    .fontWeight(.medium)
                    .lineLimit(1)
            }

            if let recipe = discoveredRecipe {
                recipeBanner(recipe)
            }

            HStack {
                Text("\(candidates.count) candidate\(candidates.count == 1 ? "" : "s") found")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Select all") { picked = Set(candidates.map { $0.url }) }
                    .buttonStyle(.link)
                    .disabled(candidates.isEmpty)
                Button("Clear") { picked = [] }
                    .buttonStyle(.link)
                    .disabled(picked.isEmpty)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(candidates) { c in
                        candidateRow(c)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.quaternary.opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            tagFields

            if picked.count > 1 || (discoveredRecipe != nil && includeRecipe && !picked.isEmpty) {
                Toggle("Link picks to the source page", isOn: $linkSourceTogether)
                    .help("Add an undirected link between every picked item and the source page item (spokes).")
                if picked.count > 1 {
                    Toggle("Also cross-link picks to each other (clique)", isOn: $cliqueLinks)
                        .help("Add a link between every pair of picked items in addition to the source-page spokes. N×(N−1)/2 edges — keep groups small (≤15).")
                }
            }
        }
    }

    private func recipeBanner(_ recipe: RecipeData) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: $includeRecipe)
                .labelsHidden()
            Image(systemName: "fork.knife.circle.fill")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Recipe Detected: \(recipe.title)")
                        .font(.callout)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    Text("RECIPE CARD")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.2), in: Capsule())
                        .foregroundStyle(.orange)
                }
                Text("\(recipe.ingredients.count) ingredients • \(recipe.instructions.count) steps\(recipe.totalTime.map { " • \($0)" } ?? "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.orange.opacity(0.25), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { includeRecipe.toggle() }
    }

    private func candidateRow(_ c: StashCLI.FetchURLCandidate) -> some View {
        let isOn = Binding(
            get: { picked.contains(c.url) },
            set: { newValue in
                if newValue { picked.insert(c.url) } else { picked.remove(c.url) }
            }
        )
        let popID = "cand-\(c.url)"
        return HStack(spacing: 10) {
            Toggle("", isOn: isOn)
                .labelsHidden()
            if c.kind == "image" {
                FetchURLThumbnailView(
                    remoteURLString: c.url,
                    localStorePath: nil,
                    popoverID: popID,
                    activePopoverID: $activePopoverID
                )
            } else {
                Image(systemName: "link")
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(c.label.isEmpty ? "(no label)" : c.label)
                    .font(.callout)
                    .lineLimit(1)
                Text(c.url)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if let size = c.size, size > 0 {
                Text(formatBytes(size))
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { isOn.wrappedValue.toggle() }
    }

    // MARK: - Direct-file result

    private var directBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if let dURL = directURL, (directMIME?.hasPrefix("image/") == true || isLikelyImageURL(dURL)) {
                    FetchURLThumbnailView(
                        remoteURLString: dURL,
                        localStorePath: nil,
                        popoverID: "direct-\(dURL)",
                        activePopoverID: $activePopoverID
                    )
                } else {
                    Image(systemName: "doc")
                        .font(.title2)
                        .foregroundStyle(.tint)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(directTitle ?? (directURL.map { ($0 as NSString).lastPathComponent } ?? "(file)"))
                        .font(.callout)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    if let mime = directMIME {
                        Text("\(mime) • \(formatBytes(directSize))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }

            tagFields
        }
    }

    private var tagFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Tags (comma-separated)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    FilterField(placeholder: "research, design", text: $extraTags)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Collection")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    FilterField(placeholder: "(optional)", text: $collection)
                }
            }
        }
    }

    // MARK: - Done state

    @ViewBuilder
    private var doneBody: some View {
        let importedItems = pickSummary?.imported ?? []
        let totalCount = importedItems.count + (stashedRecipeItem != nil ? 1 : 0)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Stashed \(totalCount) item\(totalCount == 1 ? "" : "s")")
                    .font(.callout)
                    .fontWeight(.medium)
            }
            if let linked = pickSummary?.linkedTo, !linked.isEmpty {
                Text("Cross-linked with source page item \(linked).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let errs = pickSummary?.errors, !errs.isEmpty {
                Text("\(errs.count) error\(errs.count == 1 ? "" : "s") during fetch:")
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
                .frame(maxHeight: 120)
            }
            if !importedItems.isEmpty || stashedRecipeItem != nil {
                Divider()
                Text("Imported")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        if let recipeItem = stashedRecipeItem {
                            HStack(spacing: 8) {
                                Image(systemName: "fork.knife")
                                    .foregroundStyle(.orange)
                                    .frame(width: 36, height: 36)
                                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(recipeItem.title)
                                        .font(.callout)
                                        .fontWeight(.medium)
                                        .lineLimit(1)
                                    Text("Recipe Card • #recipe")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("View Recipe") {
                                    store.selectItemByID(recipeItem.id, revealInList: true)
                                    dismiss()
                                }
                                .controlSize(.small)
                                .focusable(false)
                            }
                            .padding(.vertical, 2)
                        }
                        ForEach(importedItems) { item in
                            importedItemRow(item)
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
        }
    }

    private func importedItemRow(_ item: StashCLI.FetchURLPickedItem) -> some View {
        let matchedStoreItem = store.items.first(where: { $0.id == item.id })
        let isImage = item.type == "image" || isLikelyImageURL(item.url) || isLikelyImageURL(item.title)
        let popID = "imp-\(item.id)"
        return HStack(spacing: 8) {
            if isImage {
                FetchURLThumbnailView(
                    remoteURLString: item.url,
                    localStorePath: matchedStoreItem?.storePath,
                    popoverID: popID,
                    activePopoverID: $activePopoverID
                )
            } else {
                Image(systemName: itemTypeIcon(item.type))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }
            Text(item.title)
                .font(.callout)
                .lineLimit(1)
            Spacer()
        }
        .padding(.vertical, 2)
    }

    private func isLikelyImageURL(_ str: String) -> Bool {
        let lower = str.lowercased()
        for ext in [".jpg", ".jpeg", ".png", ".gif", ".webp", ".heic", ".bmp", ".tiff", ".svg"] {
            if lower.hasSuffix(ext) || lower.contains("\(ext)?") {
                return true
            }
        }
        return false
    }

    private func itemTypeIcon(_ type: String) -> String {
        switch type {
        case "image": return "photo"
        case "file": return "doc"
        case "link": return "link"
        default: return "questionmark"
        }
    }

    // MARK: - Footer

    private var footerButtons: some View {
        HStack {
            Spacer()
            switch phase {
            case .done:
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            default:
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Stash") { runStash() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canStash)
            }
        }
    }

    private var canStash: Bool {
        switch phase {
        case .page: return !picked.isEmpty || (discoveredRecipe != nil && includeRecipe)
        case .direct: return directURL != nil
        default: return false
        }
    }

    // MARK: - Actions

    private func runDiscover() {
        let trimmed = url.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let normalized = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        if normalized != url { url = normalized }
        error = nil
        phase = .discovering
        candidates = []
        picked = []
        directURL = nil
        pickSummary = nil
        discoveredRecipe = nil
        stashedRecipeItem = nil
        activePopoverID = nil
        let allLinksFlag = allLinks
        Task {
            async let discoverTask = StashCLI().fetchURLDiscover(url: normalized, allLinks: allLinksFlag)
            async let recipeTask: RecipeData? = {
                guard let u = URL(string: normalized) else { return nil }
                return try? await RecipeExtractor.extract(from: u)
            }()

            do {
                let result = try await discoverTask
                let recipe = await recipeTask
                await MainActor.run {
                    self.discoveredRecipe = recipe
                    self.includeRecipe = (recipe != nil)
                    switch result {
                    case .page(let pURL, let title, let cands):
                        pageURL = pURL
                        pageTitle = title
                        candidates = cands
                        picked = Set(cands.filter { $0.kind == "image" }.map { $0.url })
                        phase = .page
                    case .direct(let dURL, let title, let mime, let size):
                        directURL = dURL
                        directTitle = title
                        directMIME = mime
                        directSize = size
                        phase = .direct
                    }
                }
            } catch {
                await MainActor.run {
                    self.error = "Discover failed: \(error.localizedDescription)"
                    phase = .empty
                }
            }
        }
    }

    private func runStash() {
        error = nil
        activePopoverID = nil
        let tags = extraTags
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let coll = collection.trimmingCharacters(in: .whitespaces)
        let picksToSend: [String]
        let pageURLToSend: String
        let crossLink: Bool
        let shouldSaveRecipe = (phase == .page && discoveredRecipe != nil && includeRecipe)
        let recipeToSave = shouldSaveRecipe ? discoveredRecipe : nil

        switch phase {
        case .page:
            picksToSend = candidates
                .filter { picked.contains($0.url) }
                .map { $0.url }
            pageURLToSend = pageURL
            crossLink = (picked.count > 1 || shouldSaveRecipe) && linkSourceTogether
        case .direct:
            guard let d = directURL else { return }
            picksToSend = [d]
            pageURLToSend = d   // direct file: no source page
            crossLink = false
        default:
            return
        }
        guard !picksToSend.isEmpty || recipeToSave != nil else { return }
        phase = .stashing
        Task {
            var pickResult: StashCLI.FetchURLPickResult? = nil
            if !picksToSend.isEmpty {
                pickResult = await store.fetchURLPick(
                    pageURL: pageURLToSend,
                    picks: picksToSend,
                    linkSource: crossLink,
                    clique: picked.count > 1 && cliqueLinks,
                    archive: false,
                    tags: tags,
                    collection: coll.isEmpty ? nil : coll
                )
            }

            var savedRecipeItem: StashItem? = nil
            if let recipe = recipeToSave {
                savedRecipeItem = await store.stashRecipeFromURL(
                    pageURL: pageURLToSend,
                    recipe: recipe,
                    linkedItemID: pickResult?.linkedTo,
                    extraTags: tags,
                    collection: coll.isEmpty ? nil : coll
                )
            }

            await MainActor.run {
                if let pickResult {
                    self.pickSummary = pickResult
                    self.stashedRecipeItem = savedRecipeItem
                    self.phase = .done
                } else if let savedRecipeItem {
                    self.pickSummary = StashCLI.FetchURLPickResult(imported: [], linkedTo: nil, errors: nil)
                    self.stashedRecipeItem = savedRecipeItem
                    self.phase = .done
                } else {
                    self.phase = .page
                }
            }
        }
    }

    // MARK: - Format helpers

    private func formatBytes(_ bytes: Int64) -> String {
        let units: [(scale: Double, suffix: String)] = [
            (1_073_741_824, " GB"),
            (1_048_576, " MB"),
            (1_024, " KB"),
        ]
        for u in units {
            if Double(bytes) >= u.scale {
                return String(format: "%.1f%@", Double(bytes) / u.scale, u.suffix)
            }
        }
        return "\(bytes) B"
    }
}

// MARK: - Thumbnail + Grow-Animated Popover

/// Interactive 36×36 thumbnail used in `FetchURLSheet` for both candidate rows
/// and imported items. Clicking the thumbnail opens a popover with a smooth
/// spring grow animation. Clicking on or outside the popover dismisses it.
struct FetchURLThumbnailView: View {
    let remoteURLString: String
    let localStorePath: String?
    let popoverID: String
    @Binding var activePopoverID: String?

    @State private var image: NSImage?
    @State private var isLoading = false

    private var isPopoverPresented: Bool {
        activePopoverID == popoverID
    }

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else if isLoading {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary.opacity(0.6))
                    .frame(width: 36, height: 36)
                    .overlay(ProgressView().controlSize(.mini))
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary.opacity(0.5))
                    .frame(width: 36, height: 36)
                    .overlay(
                        Image(systemName: "photo")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    )
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onHover { hovering in
            guard image != nil else { return }
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .highPriorityGesture(
            TapGesture().onEnded {
                guard image != nil else { return }
                if isPopoverPresented {
                    activePopoverID = nil
                } else {
                    activePopoverID = popoverID
                }
            }
        )
        .popover(
            isPresented: Binding(
                get: { isPopoverPresented },
                set: { newValue in
                    if !newValue && isPopoverPresented {
                        activePopoverID = nil
                    }
                }
            ),
            arrowEdge: .trailing
        ) {
            if let image {
                EnlargedImagePopoverContent(image: image, title: (remoteURLString as NSString).lastPathComponent) {
                    activePopoverID = nil
                }
            }
        }
        .help(image != nil ? "Click to enlarge preview" : remoteURLString)
        .task(id: "\(remoteURLString)|\(localStorePath ?? "")") {
            await loadImage()
        }
    }

    private func loadImage() async {
        // 1. Check local storePath first if available
        if let storePath = localStorePath,
           let fileURL = FilePathResolver.resolve(storePath: storePath) {
            if let cached = ThumbnailCache.shared.image(forPath: fileURL.path) {
                self.image = cached
                return
            }
            isLoading = true
            let loaded = await ThumbnailCache.shared.loadAsync(path: fileURL.path)
            isLoading = false
            if let loaded {
                self.image = loaded
                return
            }
        }

        // 2. Check cache by remote URL key
        let cacheKey = "remote:\(remoteURLString)"
        if let cached = ThumbnailCache.shared.image(forPath: cacheKey) {
            self.image = cached
            return
        }

        guard let url = URL(string: remoteURLString) else { return }
        isLoading = true
        defer { isLoading = false }

        let fetched: NSImage? = await Task.detached(priority: .utility) {
            var req = URLRequest(url: url, timeoutInterval: 12)
            req.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                forHTTPHeaderField: "User-Agent"
            )
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  let http = resp as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  !data.isEmpty else {
                return nil
            }
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                return NSImage(data: data)
            }
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 900,
            ]
            if let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) {
                return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
            return NSImage(data: data)
        }.value

        if let fetched {
            ThumbnailCache.shared.inject(fetched, forPath: cacheKey)
            self.image = fetched
        }
    }
}

/// Enlarged image popover content that animates with a smooth spring "grow"
/// effect on appear and dismisses when clicked directly (or when clicking outside).
struct EnlargedImagePopoverContent: View {
    let image: NSImage
    var title: String? = nil
    let onDismiss: () -> Void

    @State private var appeared = false

    private var targetSize: CGSize {
        let natural = image.size
        guard natural.width > 0, natural.height > 0 else {
            return CGSize(width: 380, height: 380)
        }
        let maxDim: CGFloat = 460
        let minDim: CGFloat = 220
        let aspect = natural.width / natural.height
        var w = min(natural.width, maxDim)
        var h = w / aspect
        if h > maxDim {
            h = maxDim
            w = h * aspect
        }
        if w < minDim && h < minDim {
            if aspect >= 1 {
                w = minDim
                h = w / aspect
            } else {
                h = minDim
                w = h * aspect
            }
        }
        return CGSize(width: round(w), height: round(h))
    }

    var body: some View {
        let size = targetSize
        VStack(spacing: 0) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(8)
        .scaleEffect(appeared ? 1.0 : 0.45)
        .opacity(appeared ? 1.0 : 0.0)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.18, dampingFraction: 0.85)) {
                appeared = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                onDismiss()
            }
        }
        .onHover { hovering in
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .help("Click anywhere on or off the preview to dismiss")
        .onAppear {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.76)) {
                appeared = true
            }
        }
    }
}

