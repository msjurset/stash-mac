import AVKit
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Best-guess MIME for an AVURLAsset based on the original file's
/// extension. The Mac stores blobs content-addressed (no extension
/// on disk), so AVFoundation can't sniff one from the URL — and
/// when the server-recorded MIME is wrong (Google Recorder ships
/// .m4a files with Content-Type: audio/mpeg, which AVFoundation
/// then misreads as MP3), playback silently fails. Looking up the
/// type from the source filename's extension via UTType gives a
/// reliable answer because the extension itself is preserved on
/// the item's sourcePath. Returns nil when we can't resolve, so
/// callers can fall back to whatever the server recorded.
private func mediaMIMEHint(forSourcePath sourcePath: String?, mimeType: String?) -> String? {
    if let sourcePath, let ext = (sourcePath as NSString).pathExtension.nilIfEmpty,
       let utType = UTType(filenameExtension: ext),
       let mime = utType.preferredMIMEType {
        return mime
    }
    return mimeType
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

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
                    DirectMediaPlayer(
                        url: url,
                        isVideo: false,
                        mimeHint: mediaMIMEHint(
                            forSourcePath: item.sourcePath,
                            mimeType: item.mimeType
                        )
                    )
                    .frame(maxWidth: .infinity)
                }

            case .videoTapToPlay(let url):
                if videoActivated {
                    DirectMediaPlayer(
                        url: url,
                        isVideo: true,
                        mimeHint: mediaMIMEHint(
                            forSourcePath: item.sourcePath,
                            mimeType: item.mimeType
                        )
                    )
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
    /// MIME the player should report to AVFoundation. Caller-derived
    /// from the item's source filename extension (preferred) or its
    /// stored mimeType (fallback). Bypasses the
    /// AVFoundation-can't-sniff-extensionless-files problem the
    /// content-addressed blob store creates.
    var mimeHint: String?
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
                if isVideo {
                    AVPlayerNSView(url: url, isVideo: true, mimeHint: mimeHint)
                        .frame(height: 360)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    // Audio path: skip AVPlayerView entirely. Its
                    // control bar paints a translucent gray pill
                    // that there's no public way to suppress, and
                    // it looked out of place against Stash's dark
                    // surface. CustomAudioPlayer is a thin SwiftUI
                    // shell over AVPlayer with our own controls and
                    // zero background chrome.
                    CustomAudioPlayer(url: url, mimeHint: mimeHint)
                        .frame(height: 36)
                }
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
            let asset = AVURLAsset(url: url, options: assetOptions())
            let playable = (try? await asset.load(.isPlayable)) ?? false
            status = playable ? .playable : .notPlayable
        }
    }

    private func assetOptions() -> [String: Any]? {
        guard let mimeHint else { return nil }
        return ["AVURLAssetOutOfBandMIMETypeKey": mimeHint]
    }
}

private struct AVPlayerNSView: NSViewRepresentable {
    let url: URL
    let isVideo: Bool
    /// Optional out-of-band MIME hint — applied to the AVURLAsset
    /// so AVFoundation parses the bytes against the right
    /// container format. Without this, an extensionless blob
    /// labeled with the wrong MIME (e.g. Google Recorder's
    /// .m4a-as-audio/mpeg quirk) won't play.
    var mimeHint: String?

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = isVideo ? .floating : .default
        view.showsFullScreenToggleButton = isVideo
        view.allowsPictureInPicturePlayback = isVideo
        // Clear the view's own backdrop so only AVKit's control
        // pill draws — without this the gray fill of the NSView
        // extends edge-to-edge inside our frame, showing as
        // padding on either side of the audio control bar.
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.player = AVPlayer(playerItem: makeItem())
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if let current = nsView.player?.currentItem,
           let asset = current.asset as? AVURLAsset,
           asset.url == url {
            return
        }
        nsView.player?.replaceCurrentItem(with: makeItem())
    }

    private func makeItem() -> AVPlayerItem {
        let opts: [String: Any]? = mimeHint.map {
            ["AVURLAssetOutOfBandMIMETypeKey": $0]
        }
        let asset = AVURLAsset(url: url, options: opts)
        return AVPlayerItem(asset: asset)
    }
}

/// Pure-SwiftUI audio control bar. Sits on whatever background the
/// parent draws (transparent by default) and renders only the
/// controls — no AVPlayerView chrome, no translucent pill. Layout:
///   [⏮15] [▶︎/⏸] [⏭15]  current  ━━●━━━━━━  total
///
/// Time observers update the displayed position once per ~200ms.
/// Scrubber edits seek immediately. Mime hint flows into the asset
/// just like the video path so extensionless content-addressed
/// blobs play correctly.
private struct CustomAudioPlayer: View {
    let url: URL
    var mimeHint: String?

    @State private var player = AVPlayer()
    @State private var isPlaying = false
    @State private var currentSeconds: Double = 0
    @State private var durationSeconds: Double = 0
    @State private var scrubbingTo: Double? = nil
    @State private var timeObserver: Any? = nil
    @State private var endObserver: NSObjectProtocol? = nil

    var body: some View {
        HStack(spacing: 10) {
            Button(action: { skip(-15) }) {
                Image(systemName: "gobackward.15")
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)
            .help("Skip back 15s")

            Button(action: togglePlayPause) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 20))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)

            Button(action: { skip(15) }) {
                Image(systemName: "goforward.15")
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)
            .help("Skip forward 15s")

            Text(formatTime(scrubbingTo ?? currentSeconds))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)

            Slider(
                value: Binding(
                    get: { scrubbingTo ?? currentSeconds },
                    set: { newValue in scrubbingTo = newValue }
                ),
                in: 0...(max(durationSeconds, 0.1)),
                onEditingChanged: { editing in
                    if !editing, let target = scrubbingTo {
                        seek(to: target)
                        scrubbingTo = nil
                    }
                }
            )

            Text(formatTime(durationSeconds))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
        }
        .padding(.horizontal, 4)
        .task(id: url) {
            await loadAndObserve()
        }
        .onDisappear { tearDown() }
    }

    // MARK: - Lifecycle

    private func loadAndObserve() async {
        let opts: [String: Any]? = mimeHint.map {
            ["AVURLAssetOutOfBandMIMETypeKey": $0]
        }
        let asset = AVURLAsset(url: url, options: opts)
        let item = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: item)
        if let dur = try? await asset.load(.duration) {
            durationSeconds = max(0, CMTimeGetSeconds(dur))
        }

        // 5Hz position tick — fine enough for a scrubber, light
        // enough to not thrash the UI.
        let interval = CMTime(seconds: 0.2, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            currentSeconds = max(0, CMTimeGetSeconds(time))
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { _ in
            isPlaying = false
            // Snap back to the start so the next play tap restarts.
            player.seek(to: .zero)
            currentSeconds = 0
        }
    }

    private func tearDown() {
        if let observer = timeObserver {
            player.removeTimeObserver(observer)
            timeObserver = nil
        }
        if let observer = endObserver {
            NotificationCenter.default.removeObserver(observer)
            endObserver = nil
        }
        player.pause()
    }

    // MARK: - Actions

    private func togglePlayPause() {
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    private func skip(_ deltaSeconds: Double) {
        let target = (scrubbingTo ?? currentSeconds) + deltaSeconds
        seek(to: target.clamped(to: 0...max(durationSeconds, 0.1)))
    }

    private func seek(to seconds: Double) {
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
