import SwiftUI
import AppKit

/// Detail pane for the Inbox. Renders either a preview of the
/// highlighted feed candidate or the full ItemDetailView for the
/// highlighted resurface item. Nothing selected → quiet empty state.
struct InboxDetailView: View {
    @Environment(StashStore.self) private var store
    // ItemDetailView wants a binding; the inbox doesn't have an edit
    // sheet of its own, so we route through a no-op binding. Users
    // who want full editing can click "Reveal in List" first.
    @State private var showEditSheet = false

    var body: some View {
        Group {
            if let candidate = store.inboxSelectedCandidate {
                FeedCandidatePreview(candidate: candidate)
            } else if let item = store.inboxSelectedResurfaceItem {
                ItemDetailView(item: item, showEditSheet: $showEditSheet)
            } else {
                ContentUnavailableView(
                    "Nothing to preview",
                    systemImage: "tray",
                    description: Text("Select a row on the left to see its details here.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Read-only preview of a single feed candidate. Big hero thumbnail
/// when available, source attribution, full description rendered as
/// Markdown (HTML → MD conversion already happens at stash time, but
/// the description is still raw HTML in the candidate row, so we run
/// the same converter inline here for preview parity).
private struct FeedCandidatePreview: View {
    @Environment(StashStore.self) private var store
    let candidate: FeedCandidate

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let thumb = candidate.thumbnailUrl,
                   let url = URL(string: thumb) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let img):
                            img.resizable().scaledToFit()
                        default:
                            placeholderHero
                        }
                    }
                    .frame(maxWidth: 480, maxHeight: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(candidate.displayTitle)
                        .font(.title2).bold()
                    HStack(spacing: 6) {
                        if let s = candidate.sourceName {
                            Text(s)
                        }
                        Text("·").foregroundStyle(.tertiary)
                        Text(candidate.displayWhen, style: .relative)
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }

                if let urlStr = URL(string: candidate.url) {
                    Link(destination: urlStr) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.right.square")
                            Text(candidate.url)
                                .truncationMode(.middle)
                                .lineLimit(1)
                        }
                        .font(.callout)
                    }
                }

                if let md = previewMarkdown, !md.isEmpty {
                    Divider()
                    // Prefer the Markdown cached at poll time by the
                    // Go-side converter; fall back to a crude HTML
                    // strip for pre-cache rows so the preview isn't
                    // blank. `stash feeds reconvert` back-fills the
                    // legacy rows on demand.
                    MarkdownText(md)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Divider()
                HStack(spacing: 10) {
                    Button {
                        store.stashCandidate(candidate)
                    } label: {
                        Label("Stash", systemImage: "tray.and.arrow.down.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    Button {
                        store.snoozeCandidate(candidate, duration: "24h")
                    } label: {
                        Label("Snooze 1 day", systemImage: "clock.arrow.circlepath")
                    }
                    Button(role: .destructive) {
                        store.dismissCandidate(candidate)
                    } label: {
                        Label("Dismiss", systemImage: "xmark.circle")
                    }
                    Spacer()
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var placeholderHero: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.secondary.opacity(0.1))
            .overlay(
                Image(systemName: "photo")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
            )
    }

    /// Source of the preview body. Prefers the Markdown cached by the
    /// Go-side `HTMLToMarkdown` at poll time (`description_markdown`
    /// column) so the render is a single source of truth. Legacy
    /// candidates without the cache fall back to an `NSAttributedString`
    /// strip — readable but loses headings/lists/links. `stash feeds
    /// reconvert` populates the cache for those rows.
    private var previewMarkdown: String? {
        if let md = candidate.descriptionMarkdown, !md.isEmpty {
            return md
        }
        guard let desc = candidate.description, !desc.isEmpty else { return nil }
        guard desc.contains("<"),
              let data = desc.data(using: .utf8) else { return desc }
        let opts: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        if let attr = try? NSAttributedString(data: data, options: opts, documentAttributes: nil) {
            return attr.string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return desc
    }
}
