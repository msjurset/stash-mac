import AVKit
import AppKit
import SwiftUI
import WebKit

/// Top-level media area for the detail view. Switches layout based
/// on the item's media shape:
///
///  - **Embed (YouTube/Vimeo)** — render iframe player only; the
///    embed itself shows the thumbnail before play, so a separate
///    Stash thumbnail tile would be redundant.
///  - **Direct audio (file or stream)** — thumbnail tile on the
///    left, AVPlayer audio bar on the right. Thumbnail provides
///    visual context (album art, hero image) while the audio plays.
///  - **Direct video (file or stream)** — thumbnail tile with a play
///    button overlay; clicking the play button replaces the tile
///    with an inline AVPlayer.
///  - **Image / generic file / non-media URL** — just the thumbnail
///    tile.
///  - **Snippet / email** — nothing; section is hidden entirely.
///
/// "Player" / "Thumbnail" section titles are intentionally absent.
/// The visual element labels itself; an extra `<h>` row above it is
/// noise.
struct MediaSection: View {
    let item: StashItem
    @Environment(StashStore.self) private var store

    @State private var importDialogPresented = false
    @State private var videoActivated = false

    var body: some View {
        let kind = MediaResolver.resolve(item)
        Group {
            switch layout(item: item, kind: kind) {
            case .none:
                EmptyView()

            case .thumbnailOnly:
                ThumbnailTile(
                    item: item,
                    importDialogPresented: $importDialogPresented
                )

            case .embed(let url):
                EmbedPlayer(embedURL: url)

            case .audioBesideThumbnail(let url):
                HStack(alignment: .center, spacing: 12) {
                    ThumbnailTile(
                        item: item,
                        importDialogPresented: $importDialogPresented
                    )
                    DirectMediaPlayer(url: url, isVideo: false)
                        .frame(maxWidth: .infinity)
                }

            case .videoTapToPlay(let url):
                if videoActivated {
                    DirectMediaPlayer(url: url, isVideo: true)
                } else {
                    ThumbnailTile(
                        item: item,
                        importDialogPresented: $importDialogPresented,
                        onPlay: { videoActivated = true }
                    )
                }
            }
        }
        .sheet(isPresented: $importDialogPresented) {
            ThumbnailImportSheet(item: item) { sourceURL in
                store.importThumbnail(itemID: item.id, from: sourceURL)
            }
        }
    }

    private enum Layout {
        case none
        case thumbnailOnly
        case embed(URL)
        case audioBesideThumbnail(URL)
        case videoTapToPlay(URL)
    }

    private func layout(item: StashItem, kind: MediaResolver.Kind) -> Layout {
        // Snippet/email: pure text — nothing useful to render here.
        // Image: the existing "Preview" section already displays the
        // source image at full resolution, so a thumbnail tile would
        // be redundant. The auto-generated canonical thumbnail still
        // exists on disk so the list-row hover popover and (future)
        // grid view can reuse it.
        if item.type == .snippet || item.type == .email || item.type == .image {
            return .none
        }
        switch kind {
        case .embed(let url):
            return .embed(url)
        case .directAudio(let url):
            return .audioBesideThumbnail(url)
        case .directVideo(let url):
            return .videoTapToPlay(url)
        case .none:
            return .thumbnailOnly
        }
    }
}

/// WKWebView host for embedded video players (YouTube, Vimeo, …).
/// 16:9 aspect ratio matches the most common embed format; the user
/// fullscreens through the embedded player's own controls.
private struct EmbedPlayer: View {
    let embedURL: URL

    var body: some View {
        EmbedWebView(url: embedURL)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .frame(maxWidth: 720)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct EmbedWebView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        let view = WKWebView(frame: .zero, configuration: config)
        view.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        load(into: view)
        return view
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if context.coordinator.lastURL != url {
            load(into: webView)
            context.coordinator.lastURL = url
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastURL: URL?
    }

    /// Load the embed inside an HTML wrapper rather than navigating
    /// to the embed URL directly. The wrapper gives the iframe a
    /// real origin (the `baseURL`), which YouTube requires before
    /// serving the player — without it, YouTube's player surfaces
    /// error 153 "Video player configuration error".
    private func load(into webView: WKWebView) {
        let html = """
        <!doctype html>
        <html><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <style>
          html,body{margin:0;padding:0;height:100%;background:#000;}
          iframe{width:100%;height:100%;border:0;}
        </style>
        </head><body>
        <iframe src="\(url.absoluteString)"
                allow="autoplay; encrypted-media; picture-in-picture; fullscreen"
                allowfullscreen></iframe>
        </body></html>
        """
        webView.loadHTMLString(html, baseURL: URL(string: "https://stash.local/"))
    }
}

/// Single component for both audio and video. Gates rendering on
/// `AVAsset.isPlayable` so unsupported codecs (raw OGG/Vorbis on
/// older macOS, exotic containers) get a clear "Open in default app"
/// fallback instead of a silent broken player.
struct DirectMediaPlayer: View {
    let url: URL
    let isVideo: Bool
    @State private var status: PlayState = .checking

    private enum PlayState { case checking, playable, notPlayable }

    var body: some View {
        Group {
            switch status {
            case .checking:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading media…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
            case .playable:
                AVPlayerNSView(url: url, isVideo: isVideo)
                    .frame(height: isVideo ? 360 : 36)
                    .clipShape(RoundedRectangle(cornerRadius: isVideo ? 6 : 4))
            case .notPlayable:
                HStack {
                    Text("Format not supported by macOS player")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open in default app") {
                        NSWorkspace.shared.open(url)
                    }
                    .controlSize(.small)
                }
                .padding(.vertical, 6)
            }
        }
        .task(id: url) {
            status = .checking
            let asset = AVURLAsset(url: url)
            let playable = (try? await asset.load(.isPlayable)) ?? false
            status = playable ? .playable : .notPlayable
        }
    }
}

private struct AVPlayerNSView: NSViewRepresentable {
    let url: URL
    let isVideo: Bool

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = isVideo ? .floating : .default
        view.showsFullScreenToggleButton = isVideo
        view.allowsPictureInPicturePlayback = isVideo
        view.player = AVPlayer(url: url)
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if let current = nsView.player?.currentItem,
           let asset = current.asset as? AVURLAsset,
           asset.url == url {
            return
        }
        nsView.player?.replaceCurrentItem(with: AVPlayerItem(url: url))
    }
}
