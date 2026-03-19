import Foundation

enum FilePathResolver {
    private static let defaultFilesDir: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".stash")
            .appendingPathComponent("files")
    }()

    /// Resolves a store path (SHA-256 hash) to an absolute file URL.
    /// The file store layout is: `<filesDir>/<hash[:2]>/<hash>`
    static func resolve(storePath: String, filesDir: URL? = nil) -> URL? {
        guard storePath.count >= 2 else { return nil }
        let base = filesDir ?? defaultFilesDir
        let prefix = String(storePath.prefix(2))
        let url = base
            .appendingPathComponent(prefix)
            .appendingPathComponent(storePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
}
