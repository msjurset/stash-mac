import Foundation

/// Locates the active bookmark file for Chrome / Firefox on macOS.
/// Mirrors the discovery logic in `cmd/stash/import_chrome.go` /
/// `cmd/stash/import_firefox.go` so the Mac UI can prefill the path
/// before the user invokes the CLI — letting them confirm or pick a
/// different file rather than typing one in. CLI is still the
/// authoritative parser; this is purely path discovery.
enum BookmarkSourceFinder {
    /// Active Chrome profile's `Bookmarks` JSON, if any. Reads the
    /// system-level `Local State` to find `profile.last_used`; falls
    /// back to the `Default` profile when that's missing or stale.
    /// Returns nil when Chrome isn't installed (or the user's never
    /// run it on this account).
    static func activeChromeBookmarks() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let root = home
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("Google")
            .appendingPathComponent("Chrome")

        let profile = chromeLastUsedProfile(in: root) ?? "Default"
        let candidate = root.appendingPathComponent(profile).appendingPathComponent("Bookmarks")
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        let fallback = root.appendingPathComponent("Default").appendingPathComponent("Bookmarks")
        return FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
    }

    /// Safari's canonical bookmarks file. Single location — Safari
    /// doesn't have profiles. Note: reading this file from a
    /// non-Safari app requires Full Disk Access at runtime; this
    /// helper only checks for the path's existence (which works
    /// without FDA on macOS), so the user gets a clear "file
    /// found, but the CLI couldn't read it" error path rather
    /// than a missing-path one.
    static func safariBookmarks() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidate = home
            .appendingPathComponent("Library")
            .appendingPathComponent("Safari")
            .appendingPathComponent("Bookmarks.plist")
        // Don't fileExists-check this one — TCC blocks the
        // stat() too on Sequoia, so the file may be present yet
        // appear "missing". Returning the canonical path always
        // lets the CLI surface the real FDA error message.
        return candidate
    }

    /// Microsoft Edge — Chromium-family, same JSON format as Chrome.
    static func activeEdgeBookmarks() -> URL? {
        chromiumProfileBookmarks(appSupportDir: "Microsoft Edge")
    }

    /// Brave — Chromium-family.
    static func activeBraveBookmarks() -> URL? {
        chromiumProfileBookmarks(appSupportDir: "BraveSoftware/Brave-Browser")
    }

    /// Arc browser — Chromium-family. Profile lives under
    /// `User Data/<profile>/Bookmarks`, an extra layer compared
    /// to other Chromium variants.
    static func activeArcBookmarks() -> URL? {
        chromiumProfileBookmarks(appSupportDir: "Arc/User Data")
    }

    /// Vivaldi — Chromium-family.
    static func activeVivaldiBookmarks() -> URL? {
        chromiumProfileBookmarks(appSupportDir: "Vivaldi")
    }

    /// Opera — Chromium-family. Opera doesn't use a profile dir;
    /// bookmarks are at the app-support root.
    static func activeOperaBookmarks() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidate = home
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("com.operasoftware.Opera")
            .appendingPathComponent("Bookmarks")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    /// Vanilla Chromium (the OSS upstream of all the variants).
    static func activeChromiumBookmarks() -> URL? {
        chromiumProfileBookmarks(appSupportDir: "Chromium")
    }

    /// Shared Chromium-family profile-aware lookup. Reads the
    /// browser's `Local State` to pick the last-used profile; falls
    /// back to `Default`. Mirrors `activeChromeBookmarks`.
    private static func chromiumProfileBookmarks(appSupportDir: String) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let root = home
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent(appSupportDir)
        let profile = chromeLastUsedProfile(in: root) ?? "Default"
        let candidate = root.appendingPathComponent(profile).appendingPathComponent("Bookmarks")
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        let fallback = root.appendingPathComponent("Default").appendingPathComponent("Bookmarks")
        return FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
    }

    /// Default Firefox profile's `places.sqlite`. Reads
    /// `profiles.ini` to find the section with `Default=1`; if
    /// nothing is named, picks the first `*.default*` directory under
    /// `Profiles/`.
    static func defaultFirefoxPlaces() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let root = home
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("Firefox")
        let ini = root.appendingPathComponent("profiles.ini")

        if let profile = firefoxDefaultProfile(in: ini) {
            let candidate = root.appendingPathComponent(profile)
                .appendingPathComponent("places.sqlite")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        // Fallback: scan Profiles/ for a *.default* directory.
        let profilesDir = root.appendingPathComponent("Profiles")
        if let entries = try? FileManager.default.contentsOfDirectory(at: profilesDir, includingPropertiesForKeys: nil) {
            for entry in entries where entry.lastPathComponent.contains(".default") {
                let candidate = entry.appendingPathComponent("places.sqlite")
                if FileManager.default.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        return nil
    }

    // MARK: - Implementation

    private static func chromeLastUsedProfile(in root: URL) -> String? {
        let localState = root.appendingPathComponent("Local State")
        guard let data = try? Data(contentsOf: localState),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = obj["profile"] as? [String: Any] else {
            return nil
        }
        if let last = profile["last_used"] as? String, !last.isEmpty {
            return last
        }
        if let actives = profile["last_active_profiles"] as? [String], let first = actives.first {
            return first
        }
        return nil
    }

    /// Parse `profiles.ini` and return the relative path of the
    /// section that has `Default=1`. Hand-rolled because INI parsing
    /// is small; bringing in a parser dependency for a single 30-line
    /// file would be overkill.
    private static func firefoxDefaultProfile(in ini: URL) -> String? {
        guard let raw = try? String(contentsOf: ini, encoding: .utf8) else { return nil }
        var inProfileSection = false
        var path: String?
        var isDefault = false
        var found: String?
        let commit: () -> Void = {
            if inProfileSection, isDefault, let p = path, found == nil {
                found = p
            }
        }
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                commit()
                inProfileSection = trimmed.hasPrefix("[Profile")
                path = nil
                isDefault = false
                continue
            }
            guard inProfileSection else { continue }
            if let eq = trimmed.firstIndex(of: "=") {
                let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
                let value = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                switch key {
                case "Path":
                    path = value
                case "Default":
                    if value == "1" { isDefault = true }
                default: break
                }
            }
        }
        commit()
        return found
    }
}
