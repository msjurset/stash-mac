import AppKit
import WebKit

/// Errors raised by the WKWebView render path. Bubble up through
/// `ThumbnailService.importViaWebKit` and the store's fallback chain
/// so callers can decide whether to fall back further (QuickLook).
enum WebThumbnailError: Error, LocalizedError {
    case timeout
    case snapshotFailed

    var errorDescription: String? {
        switch self {
        case .timeout:        return "WebKit render timed out"
        case .snapshotFailed: return "WebKit snapshot returned no image"
        }
    }
}

/// Renders a URL in an off-screen WKWebView and snapshots the
/// rendered viewport as an NSImage. Used when the CLI's static-HTML
/// scrape returns no thumbnail candidates — JS-heavy pages like
/// Amazon product listings or single-page apps often produce a thin
/// HTML response whose <head> is empty until the client renders.
/// WKWebView runs the same engine Safari uses, so the snapshot
/// captures what the user would actually see.
@MainActor
final class WebThumbnailRenderer {
    static let shared = WebThumbnailRenderer()

    /// Load `url`, wait for didFinish, let async JS settle for
    /// `settleDelay`, then snapshot. Returns the rendered NSImage.
    /// Times out after `timeout` so a hung page or infinite redirect
    /// can't pin the WebView indefinitely.
    func render(
        url: URL,
        viewport: CGSize = CGSize(width: 1024, height: 768),
        settleDelay: Duration = .seconds(2),
        timeout: Duration = .seconds(20)
    ) async throws -> NSImage {
        // Each render gets a fresh session — easier than reusing one
        // WKWebView across calls (avoids stale state, cancellation
        // races, and lets the WebView dealloc once we're done).
        let session = RenderSession(
            url: url,
            viewport: viewport,
            settleDelay: settleDelay,
            timeout: timeout
        )
        return try await session.run()
    }
}

/// One render request. Owns the WKWebView for its lifetime, drives
/// the load → settle → snapshot sequence, and resolves the
/// continuation exactly once via `finish(_:)` so neither the timeout
/// path nor a delegate callback can double-resume.
@MainActor
private final class RenderSession: NSObject, WKNavigationDelegate {
    let url: URL
    let viewport: CGSize
    let settleDelay: Duration
    let timeout: Duration

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<NSImage, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var didFinish = false

    init(url: URL, viewport: CGSize, settleDelay: Duration, timeout: Duration) {
        self.url = url
        self.viewport = viewport
        self.settleDelay = settleDelay
        self.timeout = timeout
        super.init()
    }

    func run() async throws -> NSImage {
        return try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            start()
        }
    }

    private func start() {
        let config = WKWebViewConfiguration()
        // Default preferences are fine — JS enabled, no autoplay
        // configured (unused for thumbnail snapshots anyway).
        let frame = NSRect(origin: .zero, size: viewport)
        let webView = WKWebView(frame: frame, configuration: config)
        // WKWebView's default User-Agent omits the "Version/… Safari/…"
        // suffix, which several large sites (Amazon, Cloudflare-fronted
        // pages, news sites with bot walls) flag as headless and serve
        // a stripped landing page or sprite-sheet placeholder. Spoofing
        // a current Safari UA gets us the same content a regular
        // browser sees. Matches the UA used by the CLI's
        // `internal/fetch.URL` and `cmd/stash/check.tryRequest`.
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        webView.navigationDelegate = self
        self.webView = webView

        // Hard cap so a hanging request can't keep the renderer alive
        // forever. Cancelled the moment we resume the continuation.
        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: self?.timeout ?? .seconds(20))
            self?.finish(.failure(WebThumbnailError.timeout))
        }

        webView.load(URLRequest(url: url))
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor [weak self] in
            await self?.scheduleSnapshot()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor [weak self] in
            self?.finish(.failure(error))
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor [weak self] in
            self?.finish(.failure(error))
        }
    }

    private func scheduleSnapshot() async {
        // Guard against duplicate didFinish (rare but documented for
        // some redirect chains).
        guard !didFinish else { return }
        didFinish = true
        try? await Task.sleep(for: settleDelay)
        snapshot()
    }

    private func snapshot() {
        guard let webView else { return }
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = NSNumber(value: Double(viewport.width))
        webView.takeSnapshot(with: config) { [weak self] image, error in
            Task { @MainActor in
                if let image {
                    self?.finish(.success(image))
                } else {
                    self?.finish(.failure(error ?? WebThumbnailError.snapshotFailed))
                }
            }
        }
    }

    /// Resume the continuation exactly once. Subsequent calls are
    /// no-ops so a late delegate callback or the timeout firing after
    /// success doesn't crash on double-resume.
    private func finish(_ result: Result<NSImage, Error>) {
        guard let cont = continuation else { return }
        continuation = nil
        timeoutTask?.cancel()
        // Nil out the WebView so it (and its content process) tears
        // down once the closure scope exits.
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
        switch result {
        case .success(let img): cont.resume(returning: img)
        case .failure(let err): cont.resume(throwing: err)
        }
    }
}
