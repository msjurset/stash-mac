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

    // MARK: - Items

    func listItems(
        type: ItemType? = nil,
        tag: String? = nil,
        collection: String? = nil,
        limit: Int = 50
    ) async throws -> [StashItem] {
        var args = ["list", "--json", "-l", "\(limit)"]
        if let type { args += ["--type", type.rawValue] }
        if let tag { args += ["--tag", tag] }
        if let collection { args += ["--collection", collection] }
        return try await captureJSON(args: args)
    }

    func searchItems(
        query: String,
        type: ItemType? = nil,
        tag: String? = nil,
        limit: Int = 50
    ) async throws -> [StashItem] {
        var args = ["search", "--json", query, "-l", "\(limit)"]
        if let type { args += ["--type", type.rawValue] }
        if let tag { args += ["--tag", tag] }
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = args

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outData, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 {
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            let errOutput = String(data: errData, encoding: .utf8) ?? ""
            let message = errOutput.isEmpty ? output : errOutput
            throw CLIError.failed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func executeWithStdin(args: [String], input: String) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
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

        process.waitUntilExit()

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outData, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 {
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            let errOutput = String(data: errData, encoding: .utf8) ?? ""
            let message = errOutput.isEmpty ? output : errOutput
            throw CLIError.failed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
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
