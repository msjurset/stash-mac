import SwiftUI
import AppKit

/// File menu → "Fetch Files via URL…" sheet. Mirrors the Chrome
/// extension's picker for a desktop-only workflow: paste a URL,
/// discover image / file candidates on the page, pick the ones to
/// stash, optionally cross-link them with the source page.
///
/// The Mac side only owns UI + selection state; discovery and
/// stashing both run through `stash fetch-url` so the headless and
/// extension paths share the same scrape + dedup + linking logic.
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
                Text("Enter a URL above and click Discover to scan the page for stashable images and files.")
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
        .frame(width: 720, height: 600)
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
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.quaternary.opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            tagFields

            if picked.count > 1 {
                Toggle("Link picks to the source page", isOn: $linkSourceTogether)
                    .help("Add an undirected link between every picked item and the source page item (spokes).")
                Toggle("Also cross-link picks to each other (clique)", isOn: $cliqueLinks)
                    .help("Add a link between every pair of picked items in addition to the source-page spokes. N×(N−1)/2 edges — keep groups small (≤15).")
            }
        }
    }

    private func candidateRow(_ c: StashCLI.FetchURLCandidate) -> some View {
        let isOn = Binding(
            get: { picked.contains(c.url) },
            set: { newValue in
                if newValue { picked.insert(c.url) } else { picked.remove(c.url) }
            }
        )
        return HStack(spacing: 8) {
            Toggle("", isOn: isOn)
                .labelsHidden()
            Image(systemName: c.kind == "image" ? "photo" : "link")
                .foregroundStyle(.secondary)
                .frame(width: 16)
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
                Image(systemName: "doc")
                    .font(.title2)
                    .foregroundStyle(.tint)
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
        if let summary = pickSummary {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Stashed \(summary.imported.count) item\(summary.imported.count == 1 ? "" : "s")")
                        .font(.callout)
                        .fontWeight(.medium)
                }
                if let linked = summary.linkedTo, !linked.isEmpty {
                    Text("Cross-linked with source page item \(linked).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let errs = summary.errors, !errs.isEmpty {
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
                if !summary.imported.isEmpty {
                    Divider()
                    Text("Imported")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(summary.imported) { item in
                                HStack(spacing: 6) {
                                    Image(systemName: itemTypeIcon(item.type))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 14)
                                    Text(item.title)
                                        .font(.caption)
                                        .lineLimit(1)
                                    Spacer()
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 160)
                }
            }
        }
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
        case .page: return !picked.isEmpty
        case .direct: return directURL != nil
        default: return false
        }
    }

    // MARK: - Actions

    private func runDiscover() {
        let trimmed = url.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        // Default to `https://` when the user omits the scheme so
        // pasting `www.example.com` Just Works — mirrors the
        // normalization AddItemSheet does for URL items.
        let normalized = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        // Reflect the normalization in the field so the user sees
        // exactly what's being fetched (and so a second Discover
        // doesn't re-normalize on top of itself).
        if normalized != url { url = normalized }
        error = nil
        phase = .discovering
        candidates = []
        picked = []
        directURL = nil
        pickSummary = nil
        let allLinksFlag = allLinks
        Task {
            do {
                let result = try await StashCLI().fetchURLDiscover(url: normalized, allLinks: allLinksFlag)
                await MainActor.run {
                    switch result {
                    case .page(let pURL, let title, let cands):
                        pageURL = pURL
                        pageTitle = title
                        candidates = cands
                        // Default selection: all images, ignore link-only by default.
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
        let tags = extraTags
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let coll = collection.trimmingCharacters(in: .whitespaces)
        let picksToSend: [String]
        let pageURLToSend: String
        let crossLink: Bool
        switch phase {
        case .page:
            picksToSend = candidates
                .filter { picked.contains($0.url) }
                .map { $0.url }
            pageURLToSend = pageURL
            crossLink = picked.count > 1 && linkSourceTogether
        case .direct:
            guard let d = directURL else { return }
            picksToSend = [d]
            pageURLToSend = d   // direct file: no source page
            crossLink = false
        default:
            return
        }
        guard !picksToSend.isEmpty else { return }
        phase = .stashing
        Task {
            let result = await store.fetchURLPick(
                pageURL: pageURLToSend,
                picks: picksToSend,
                linkSource: crossLink,
                clique: picked.count > 1 && cliqueLinks,
                archive: false,
                tags: tags,
                collection: coll.isEmpty ? nil : coll
            )
            await MainActor.run {
                if let result {
                    pickSummary = result
                    phase = .done
                } else {
                    phase = .page  // store.fetchURLPick already populated store.error
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
