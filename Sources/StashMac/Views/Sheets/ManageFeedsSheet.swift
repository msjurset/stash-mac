import SwiftUI

/// Lightweight feed-management sheet: list every subscription with
/// its health (last polled, last error), and an X button to remove.
/// Editing in place is intentionally narrow — enable/disable toggle
/// and auto-stash toggle are the two things users actually flip.
/// Full edits (rename, change URL, change interval, change tags) go
/// through the CLI: `stash feeds edit <id> ...`. The sheet shows the
/// CLI verb in its footer so the user knows where to find it.
struct ManageFeedsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(StashStore.self) private var store

    @State private var sources: [FeedSource] = []
    @State private var loading = true
    @State private var loadError: String?
    @State private var removalTarget: FeedSource?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Feed Sources").font(.title3).bold()
                Spacer()
                Button {
                    Task { await reload() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh list")
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Divider()

            if loading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadError {
                ContentUnavailableView(
                    "Couldn't load feeds",
                    systemImage: "exclamationmark.triangle",
                    description: Text(loadError)
                )
                .frame(maxHeight: .infinity)
            } else if sources.isEmpty {
                ContentUnavailableView(
                    "No feeds yet",
                    systemImage: "antenna.radiowaves.left.and.right",
                    description: Text("Add a feed from the Inbox header.")
                )
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(sources) { src in
                            row(src)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 420)
            }

            Divider()
            Text("Rename, retag, or change the URL via `stash feeds edit <id>` in your terminal.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
        }
        .frame(width: 620)
        .onAppear { Task { await reload() } }
        .confirmationDialog(
            "Remove feed?",
            isPresented: Binding(get: { removalTarget != nil }, set: { if !$0 { removalTarget = nil } }),
            presenting: removalTarget
        ) { target in
            Button("Remove “\(target.name)”", role: .destructive) {
                Task { await remove(target) }
            }
            Button("Cancel", role: .cancel) { removalTarget = nil }
        } message: { target in
            Text("This deletes the subscription and any unread candidates. Already-stashed items are kept.")
        }
    }

    @ViewBuilder
    private func row(_ src: FeedSource) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(src.name).font(.headline)
                    if src.autoStash == true {
                        Text("auto")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.tint.opacity(0.2), in: Capsule())
                            .foregroundStyle(.tint)
                    }
                    if !src.enabled {
                        Text("disabled")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.2), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
                Text(src.url)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .truncationMode(.middle)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let polled = src.lastPolledAt {
                        Text("polled \(polled.formatted(.relative(presentation: .numeric)))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    } else {
                        Text("never polled").font(.caption2).foregroundStyle(.tertiary)
                    }
                    if let err = src.lastError, !err.isEmpty {
                        Text("· \(err)")
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .lineLimit(1)
                    }
                }
            }
            Spacer()
            Button {
                removalTarget = src
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .help("Remove this feed")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private func reload() async {
        loading = true
        loadError = nil
        do {
            sources = try await StashCLI.shared.listFeedSources()
        } catch {
            loadError = error.localizedDescription
        }
        loading = false
    }

    private func remove(_ src: FeedSource) async {
        do {
            try await StashCLI.shared.removeFeedSource(id: src.id)
            removalTarget = nil
            await reload()
            store.loadInbox()
        } catch {
            loadError = error.localizedDescription
        }
    }
}
