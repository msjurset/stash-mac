import Foundation

/// JSON response from `stash check --json`.
struct CheckResult: Codable {
    var brokenUrls: [CheckIssue]?
    var orphanedFiles: [String]?
    var missingFiles: [CheckIssue]?
    var duplicateHashes: [DupeGroup]?

    var totalIssues: Int {
        (brokenUrls?.count ?? 0) +
        (orphanedFiles?.count ?? 0) +
        (missingFiles?.count ?? 0) +
        (duplicateHashes?.count ?? 0)
    }

    var isEmpty: Bool { totalIssues == 0 }
}

struct CheckIssue: Codable, Identifiable {
    var id: String
    var title: String
    var detail: String?
}

struct DupeGroup: Codable, Identifiable {
    var hash: String
    var items: [CheckIssue]

    var id: String { hash }
}
