import Foundation

actor StashCLI {
    static let shared = StashCLI()

    private var binaryPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/stash",
            "\(home)/go/bin/stash",
            "/usr/local/bin/stash",
            "/opt/homebrew/bin/stash",
            "\(home)/workspace/go/gostash/stash",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            ?? "stash"
    }

    private var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// Encoder for outbound JSON (e.g. piping a rule into `stash autotag save`).
    /// Mirrors the decoder's snake_case convention so the CLI sees field names
    /// matching its Go struct tags.
    private var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }

    // MARK: - Items

    func listItems(
        type: ItemType? = nil,
        tags: [String] = [],
        collection: String? = nil,
        limit: Int = 50
    ) async throws -> [StashItem] {
        var args = ["list", "--json", "-l", "\(limit)"]
        if let type { args += ["--type", type.rawValue] }
        for tag in tags { args += ["--tag", tag] }
        if let collection { args += ["--collection", collection] }
        return try await captureJSON(args: args)
    }

    func searchItems(
        query: String,
        type: ItemType? = nil,
        tags: [String] = [],
        limit: Int = 50
    ) async throws -> [StashItem] {
        // The query goes after `--` so cobra stops walking subcommands —
        // otherwise queries like "delete", "save", "list", or "run"
        // resolve to `stash search delete` etc. and the trailing `-l`
        // becomes an unknown flag.
        var args = ["search", "--json", "-l", "\(limit)"]
        if let type { args += ["--type", type.rawValue] }
        for tag in tags { args += ["--tag", tag] }
        args += ["--", query]
        return try await captureJSON(args: args)
    }

    func getItem(id: String) async throws -> StashItem {
        try await captureJSON(args: ["show", "--json", id])
    }

    func addURL(
        url: String,
        title: String? = nil,
        tags: [String] = [],
        note: String? = nil,
        collection: String? = nil
    ) async throws -> StashItem {
        var args = ["add", "--json", url]
        if let title { args += ["-t", title] }
        for tag in tags { args += ["-T", tag] }
        if let note { args += ["-n", note] }
        if let collection { args += ["-c", collection] }
        return try await captureJSON(args: args)
    }

    func addFile(
        path: String,
        title: String? = nil,
        tags: [String] = [],
        note: String? = nil,
        collection: String? = nil
    ) async throws -> StashItem {
        var args = ["add", "--json", path]
        if let title { args += ["-t", title] }
        for tag in tags { args += ["-T", tag] }
        if let note { args += ["-n", note] }
        if let collection { args += ["-c", collection] }
        return try await captureJSON(args: args)
    }

    func addSnippet(
        text: String,
        title: String? = nil,
        tags: [String] = [],
        note: String? = nil,
        collection: String? = nil
    ) async throws -> StashItem {
        var args = ["add", "--json", "-"]
        if let title { args += ["-t", title] }
        for tag in tags { args += ["-T", tag] }
        if let note { args += ["-n", note] }
        if let collection { args += ["-c", collection] }
        return try await captureJSONWithStdin(args: args, input: text)
    }

    func editItem(
        id: String,
        title: String? = nil,
        note: String? = nil,
        extractedText: String? = nil,
        addTags: [String] = [],
        removeTags: [String] = [],
        collection: String? = nil
    ) async throws -> StashItem {
        var args = ["edit", "--json", id]
        if let title { args += ["-t", title] }
        if let note { args += ["-n", note] }
        if let extractedText { args += ["-e", extractedText] }
        for tag in addTags { args += ["--add-tag", tag] }
        for tag in removeTags { args += ["--remove-tag", tag] }
        if let collection { args += ["-c", collection] }
        return try await captureJSON(args: args)
    }

    func deleteItem(id: String) async throws {
        _ = try await captureOutput(args: ["delete", "--json", "-y", id])
    }

    func openItem(id: String) async throws {
        _ = try await captureOutput(args: ["open", id])
    }

    // MARK: - Links

    func linkItems(from: String, to: String, label: String? = nil, directed: Bool = false) async throws {
        var args = ["link", "--json", from, to]
        if let label, !label.isEmpty { args += ["-l", label] }
        if directed { args += ["--directed"] }
        _ = try await captureOutput(args: args)
    }

    func unlinkItems(idA: String, idB: String) async throws {
        _ = try await captureOutput(args: ["unlink", "--json", idA, idB])
    }

    // MARK: - Tags

    func listTags() async throws -> [StashTag] {
        try await captureJSON(args: ["tag", "list", "--json"])
    }

    func refreshItem(id: String) async throws -> StashItem {
        try await captureJSON(args: ["refresh", "--json", id])
    }

    func tagGraph() async throws -> TagGraphData {
        try await captureJSON(args: ["tag", "graph", "--json"])
    }

    func renameTag(old: String, new: String) async throws {
        _ = try await captureOutput(args: ["tag", "rename", "--json", old, new])
    }

    // MARK: - Collections

    func listCollections() async throws -> [StashCollection] {
        try await captureJSON(args: ["collection", "list", "--json"])
    }

    func createCollection(name: String, description: String? = nil) async throws -> StashCollection {
        var args = ["collection", "create", "--json", name]
        if let description { args += ["-d", description] }
        return try await captureJSON(args: args)
    }

    func deleteCollection(name: String) async throws {
        _ = try await captureOutput(args: ["collection", "delete", "--json", name])
    }

    // MARK: - Saved Searches

    func listSavedSearches() async throws -> [SavedSearch] {
        try await captureJSON(args: ["search", "list", "--json"])
    }

    func runSavedSearch(name: String) async throws -> [StashItem] {
        try await captureJSON(args: ["search", "run", "--json", name])
    }

    func deleteSavedSearch(name: String) async throws {
        _ = try await captureOutput(args: ["search", "delete", "--json", name])
    }

    // MARK: - Duplicates

    func dupes(type: ItemType? = nil, threshold: Double = 0.7) async throws -> [DupeResult] {
        var args = ["dupes", "--json", "--threshold", "\(threshold)"]
        if let type { args += ["--type", type.rawValue] }
        return try await captureJSON(args: args)
    }

    // MARK: - Duplicate Dismissal

    func dismissDupePair(idA: String, idB: String) async throws {
        _ = try await captureOutput(args: ["dupes", "dismiss", idA, idB])
    }

    // MARK: - Stats & Check

    func stats() async throws -> StashStatsResponse {
        try await captureJSON(args: ["stats", "--json"])
    }

    func check(urls: Bool = true, files: Bool = true, dupes: Bool = true) async throws -> CheckResult {
        var args = ["check", "--json"]
        if !urls || !files || !dupes {
            if urls { args.append("--urls") }
            if files { args.append("--files") }
            if dupes { args.append("--dupes") }
        }
        return try await captureJSON(args: args)
    }

    /// Streams `stash check --stream` output as NDJSON events. Each line of
    /// stdout is decoded into a `CheckEvent` and yielded as soon as it arrives,
    /// so callers can render findings progressively.
    nonisolated func checkStream(urls: Bool = true, files: Bool = true, dupes: Bool = true) -> AsyncThrowingStream<CheckEvent, Error> {
        var args = ["check", "--stream"]
        if !urls || !files || !dupes {
            if urls { args.append("--urls") }
            if files { args.append("--files") }
            if dupes { args.append("--dupes") }
        }

        return AsyncThrowingStream { continuation in
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase

            Task.detached(priority: .userInitiated) { [args] in
                let binaryPath = await self.binaryPath
                process.executableURL = URL(fileURLWithPath: binaryPath)
                process.arguments = args

                do {
                    try process.run()
                } catch {
                    continuation.finish(throwing: error)
                    return
                }

                let handle = stdout.fileHandleForReading
                var buffer = Data()

                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    buffer.append(chunk)

                    while let newlineIdx = buffer.firstIndex(of: 0x0A) {
                        let lineData = buffer.subdata(in: 0..<newlineIdx)
                        buffer.removeSubrange(0...newlineIdx)
                        if lineData.isEmpty { continue }
                        if let event = try? decoder.decode(CheckEvent.self, from: lineData) {
                            continuation.yield(event)
                        }
                        // Malformed lines (e.g. stray log output) are skipped
                        // rather than aborting the whole stream.
                    }
                }

                process.waitUntilExit()

                if process.terminationStatus != 0 {
                    let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                    let errMsg = String(data: errData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "check failed"
                    continuation.finish(throwing: CLIError.failed(errMsg))
                    return
                }

                continuation.finish()
            }

            continuation.onTermination = { _ in
                if process.isRunning {
                    process.terminate()
                }
            }
        }
    }

    // MARK: - Rules

    func listRules() async throws -> [Rule] {
        try await captureJSON(args: ["rules", "list", "--json"])
    }

    func testRule(itemID: String) async throws -> RuleTestResult {
        try await captureJSON(args: ["rules", "test", "--json", itemID])
    }

    func setRuleEnabled(name: String, enabled: Bool) async throws {
        let verb = enabled ? "enable" : "disable"
        _ = try await captureOutput(args: ["rules", verb, "--json", name])
    }

    /// Upsert a rule by piping its JSON form to `stash rules save`. The
    /// rule's `name` is the upsert key — saving a rule with the same name
    /// replaces the existing one in the YAML, preserving comments.
    func saveRule(_ rule: Rule) async throws {
        let data = try encoder.encode(rule)
        let payload = String(data: data, encoding: .utf8) ?? "{}"
        _ = try await executeWithStdin(args: ["rules", "save", "--json"], input: payload)
    }

    func removeRule(name: String) async throws {
        _ = try await captureOutput(args: ["rules", "remove", "--json", name])
    }

    /// Rename a rule. Updates rules.yaml in place and rewrites rules.log
    /// so historical activity stays attached to the rule under its new
    /// name. Errors if `newName` collides with an existing rule.
    func renameRule(oldName: String, newName: String) async throws {
        _ = try await captureOutput(args: ["rules", "rename", "--json", oldName, newName])
    }

    /// Run rules over existing items. `ruleName` limits the run to a single
    /// rule; nil applies all enabled rules. When `dryRun` is true no writes
    /// happen but the returned summary lists the would-be changes.
    func applyRules(ruleName: String? = nil, dryRun: Bool = false) async throws -> RuleApplySummary {
        var args = ["rules", "apply", "--json"]
        if let ruleName { args += ["--rule", ruleName] }
        if dryRun { args.append("--dry-run") }
        return try await captureJSON(args: args)
    }

    /// Read the rules activity log. Calls `stash rules log --json` which
    /// emits JSONL (one Event per line); we decode line-by-line because
    /// the log isn't a single JSON document. Returns events newest-first
    /// (the CLI orders them that way already).
    ///
    /// Filters mirror the CLI flags. Pass nil to skip a filter.
    func listRuleEvents(
        type: RuleEvent.EventType? = nil,
        rule: String? = nil,
        limit: Int = 100,
        since: String? = nil
    ) async throws -> [RuleEvent] {
        var args = ["rules", "log", "--json", "-l", "\(limit)"]
        if let type { args += ["--type", type.rawValue] }
        if let rule { args += ["--rule", rule] }
        if let since { args += ["--since", since] }
        let output = try await captureOutput(args: args)
        return decodeJSONLines(output, as: RuleEvent.self)
    }

    /// Decode line-delimited JSON. Empty lines and parse errors are
    /// skipped — the rules log can in principle contain a corrupt entry
    /// (process killed mid-write), and we want to render the rest.
    private func decodeJSONLines<T: Decodable>(_ output: String, as: T.Type) -> [T] {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: true)
        return lines.compactMap { line -> T? in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(T.self, from: data)
        }
    }

    // MARK: - Bulk Operations

    func bulkTag(ids: [String], addTags: [String] = [], removeTags: [String] = []) async throws {
        var args = ["bulk", "tag", "--json"]
        for tag in addTags { args += ["--add-tag", tag] }
        for tag in removeTags { args += ["--remove-tag", tag] }
        args += ids
        _ = try await captureOutput(args: args)
    }

    func bulkDelete(ids: [String]) async throws {
        var args = ["bulk", "delete", "--json", "-y"]
        args += ids
        _ = try await captureOutput(args: args)
    }

    func bulkCollect(ids: [String], collection: String, remove: Bool = false) async throws {
        var args = ["bulk", "collect", "--json", "-c", collection]
        if remove { args.append("--remove") }
        args += ids
        _ = try await captureOutput(args: args)
    }

    // MARK: - Private

    private func captureJSON<T: Decodable>(args: [String]) async throws -> T {
        let output = try await captureOutput(args: args)
        guard let data = output.data(using: .utf8) else {
            throw CLIError.failed("Invalid UTF-8 output")
        }
        return try decoder.decode(T.self, from: data)
    }

    private func captureJSONWithStdin<T: Decodable>(args: [String], input: String) async throws -> T {
        let output = try await executeWithStdin(args: args, input: input)
        guard let data = output.data(using: .utf8) else {
            throw CLIError.failed("Invalid UTF-8 output")
        }
        return try decoder.decode(T.self, from: data)
    }

    private func captureOutput(args: [String]) async throws -> String {
        let binary = binaryPath
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: binary)
                    process.arguments = args

                    let stdout = Pipe()
                    let stderr = Pipe()
                    process.standardOutput = stdout
                    process.standardError = stderr

                    try process.run()

                    // Read pipe data BEFORE waitUntilExit to prevent deadlock
                    // when output exceeds the pipe buffer (64KB)
                    let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                    let errData = stderr.fileHandleForReading.readDataToEndOfFile()

                    process.waitUntilExit()

                    let output = String(data: outData, encoding: .utf8) ?? ""

                    if process.terminationStatus != 0 {
                        let errOutput = String(data: errData, encoding: .utf8) ?? ""
                        let message = errOutput.isEmpty ? output : errOutput
                        continuation.resume(throwing: CLIError.failed(message.trimmingCharacters(in: .whitespacesAndNewlines)))
                    } else {
                        continuation.resume(returning: output.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func executeWithStdin(args: [String], input: String) async throws -> String {
        let binary = binaryPath
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: binary)
                    process.arguments = args

                    let stdin = Pipe()
                    let stdout = Pipe()
                    let stderr = Pipe()
                    process.standardInput = stdin
                    process.standardOutput = stdout
                    process.standardError = stderr

                    try process.run()

                    if let data = input.data(using: .utf8) {
                        stdin.fileHandleForWriting.write(data)
                    }
                    stdin.fileHandleForWriting.closeFile()

                    let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                    let errData = stderr.fileHandleForReading.readDataToEndOfFile()

                    process.waitUntilExit()

                    let output = String(data: outData, encoding: .utf8) ?? ""

                    if process.terminationStatus != 0 {
                        let errOutput = String(data: errData, encoding: .utf8) ?? ""
                        let message = errOutput.isEmpty ? output : errOutput
                        continuation.resume(throwing: CLIError.failed(message.trimmingCharacters(in: .whitespacesAndNewlines)))
                    } else {
                        continuation.resume(returning: output.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

enum CLIError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let msg): return msg
        }
    }
}
