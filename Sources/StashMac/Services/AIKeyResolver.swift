import Foundation

/// Resolves API key field values. Pass-through for plain strings;
/// shells out to `op read` for `op://` references so the actual
/// secret never lives in UserDefaults — only the 1Password reference
/// does. Resolution happens just before every network call.
enum AIKeyResolver {
    enum ResolverError: LocalizedError {
        case opNotFound
        case opFailed(stderr: String, exit: Int32)

        var errorDescription: String? {
            switch self {
            case .opNotFound:
                return "1Password CLI (`op`) not found. Install with `brew install 1password-cli` and sign in via `op signin`."
            case .opFailed(let stderr, let exit):
                let snippet = stderr.count > 240 ? String(stderr.prefix(240)) + "…" : stderr
                let trimmed = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
                return "`op read` failed (exit \(exit)): \(trimmed.isEmpty ? "no stderr" : trimmed)"
            }
        }
    }

    /// If `raw` is an `op://vault/item/field` reference, runs `op
    /// read` to fetch the actual secret. Otherwise returns the
    /// trimmed input as-is.
    static func resolve(_ raw: String) async throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isReference(trimmed) else { return trimmed }
        guard let opPath = findOpBinary() else {
            throw ResolverError.opNotFound
        }
        return try await runOpRead(opPath: opPath, reference: trimmed)
    }

    /// True when the value is a 1Password reference. Used by the
    /// Settings UI to flip the placeholder + show the "via 1Password"
    /// hint line.
    static func isReference(_ raw: String) -> Bool {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .hasPrefix("op://")
    }

    /// Probe whether the 1Password CLI is installed. Used by the
    /// Settings UI to surface a Setup hint when the user pastes a
    /// reference but `op` isn't on disk.
    static var opAvailable: Bool { findOpBinary() != nil }

    private static func findOpBinary() -> String? {
        // SwiftUI apps don't inherit the user's shell PATH — search
        // the well-known install locations explicitly.
        let candidates = [
            "/opt/homebrew/bin/op",
            "/usr/local/bin/op",
            "/Applications/1Password.app/Contents/MacOS/op",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    private static func runOpRead(opPath: String, reference: String) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let proc = Process()
                    proc.executableURL = URL(fileURLWithPath: opPath)
                    proc.arguments = ["read", "--no-newline", reference]
                    let outPipe = Pipe()
                    let errPipe = Pipe()
                    proc.standardOutput = outPipe
                    proc.standardError = errPipe
                    try proc.run()
                    proc.waitUntilExit()
                    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    if proc.terminationStatus != 0 {
                        let stderr = String(data: errData, encoding: .utf8) ?? ""
                        continuation.resume(throwing: ResolverError.opFailed(stderr: stderr, exit: proc.terminationStatus))
                        return
                    }
                    let secret = (String(data: outData, encoding: .utf8) ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(returning: secret)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
