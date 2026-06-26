import Foundation

/// Pure mapping from a `StashItem` to its inline-player kind.
/// Detail view branches on the result; phase 1 covers local files
/// (mime-driven) and direct-stream URLs. Embed hosts (YouTube, Vimeo)
/// are added in phase 2 by extending `resolveURL`.
enum MediaResolver {
    enum Kind: Equatable {
        /// Local file or remote URL whose content is a video stream.
        case directVideo(URL)
        /// Local file or remote URL whose content is an audio stream.
        case directAudio(URL)
        /// Known embed host (YouTube, Vimeo, …). The associated URL
        /// is the canonical embed URL, ready to drop into a WKWebView.
        case embed(URL)
        /// No inline player.
        case none
    }

    /// File extensions we treat as direct video streams when present
    /// either on a local file or a URL path.
    private static let videoExtensions: Set<String> = [
        "mp4", "m4v", "mov", "webm", "m3u8", "mpeg", "mpg",
    ]

    /// File extensions we treat as direct audio streams. `m3u` /
    /// `m3u8` are deliberately under video — HLS playlists carry
    /// either, AVPlayer handles both, the player chrome falls out
    /// either way.
    private static let audioExtensions: Set<String> = [
        "mp3", "m4a", "aac", "wav", "aiff", "aif", "caf", "flac",
    ]

    /// Resolve an item to a player kind, or `.none` when nothing
    /// matches. Pure — no IO.
    static func resolve(_ item: StashItem) -> Kind {
        switch item.type {
        case .file:
            return resolveFile(item)
        case .url:
            return resolveURL(item)
        case .image, .snippet, .email:
            return .none
        }
    }

    private static func resolveFile(_ item: StashItem) -> Kind {
        guard let storePath = item.storePath,
              let url = FilePathResolver.resolve(storePath: storePath) else {
            return .none
        }
        if let mime = item.mimeType {
            if mime.hasPrefix("video/") { return .directVideo(url) }
            if mime.hasPrefix("audio/") { return .directAudio(url) }
        }
        // Mime missing or generic — sniff by extension as a fallback.
        let ext = (item.sourcePath ?? "").lowercased()
            .components(separatedBy: ".").last ?? ""
        if videoExtensions.contains(ext) { return .directVideo(url) }
        if audioExtensions.contains(ext) { return .directAudio(url) }
        return .none
    }

    /// True if the URL points to a known direct video extension or embed host.
    static func isVideoURL(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if videoExtensions.contains(ext) { return true }
        if embedURL(for: url) != nil { return true }
        return false
    }

    private static func resolveURL(_ item: StashItem) -> Kind {
        guard let urlString = item.url, !urlString.isEmpty,
              let url = URL(string: urlString) else { return .none }

        // Direct-stream sniff — mime first (set when a non-HTML fetch
        // landed on the item), URL extension as a fallback for paths
        // like /podcast/episode.mp3.
        if let mime = item.mimeType {
            if mime.hasPrefix("video/") { return .directVideo(url) }
            if mime.hasPrefix("audio/") { return .directAudio(url) }
        }
        let ext = url.pathExtension.lowercased()
        if videoExtensions.contains(ext) { return .directVideo(url) }
        if audioExtensions.contains(ext) { return .directAudio(url) }

        // Embed hosts. Add new entries in `embedURL(for:)` as new hosts
        // are encountered — don't preemptively cover ones the user
        // hasn't actually captured.
        if let embed = embedURL(for: url) {
            return .embed(embed)
        }
        return .none
    }

    /// Map a page URL on a known embed host to the canonical
    /// `<iframe>`-friendly embed URL. Returns nil for unknown hosts.
    static func embedURL(for url: URL) -> URL? {
        guard let host = url.host?.lowercased() else { return nil }

        // YouTube — three URL shapes share the same v=ID embed:
        //   youtube.com/watch?v=ID
        //   youtu.be/ID
        //   youtube.com/shorts/ID
        if host.hasSuffix("youtube.com") || host == "youtu.be" {
            if let id = youTubeVideoID(from: url) {
                return URL(string: "https://www.youtube.com/embed/\(id)")
            }
            return nil
        }

        // Vimeo — vimeo.com/<numeric-id>
        if host.hasSuffix("vimeo.com") {
            let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            // Skip non-video paths (categories, channels, etc.) — only
            // accept a single numeric segment.
            if !path.isEmpty, !path.contains("/"),
               path.allSatisfy({ $0.isNumber }) {
                return URL(string: "https://player.vimeo.com/video/\(path)")
            }
            return nil
        }

        return nil
    }

    private static func youTubeVideoID(from url: URL) -> String? {
        let host = url.host?.lowercased() ?? ""
        let path = url.path
        if host == "youtu.be" {
            let id = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return id.isEmpty ? nil : id
        }
        // /shorts/ID
        if path.hasPrefix("/shorts/") {
            let id = String(path.dropFirst("/shorts/".count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return id.isEmpty ? nil : id
        }
        // /watch?v=ID — and /embed/ID, /v/ID for completeness
        if path == "/watch" {
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            if let id = comps?.queryItems?.first(where: { $0.name == "v" })?.value,
               !id.isEmpty {
                return id
            }
        }
        for prefix in ["/embed/", "/v/"] {
            if path.hasPrefix(prefix) {
                let id = String(path.dropFirst(prefix.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if !id.isEmpty { return id }
            }
        }
        return nil
    }
}
