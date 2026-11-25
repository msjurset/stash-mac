import Foundation

/// Utilities for parsing, testing, prepending, and removing structured filter tokens
/// (e.g. `tag:swift`, `collection:"Reading List"`, `type:url`, `is:recipe`) within search query strings.
public struct SearchTokenHelper {
    /// Extracts tokens from query respecting double quotes.
    public static func extractTokens(from query: String) -> [String] {
        var tokens: [String] = []
        var i = query.startIndex
        while i < query.endIndex {
            while i < query.endIndex && query[i].isWhitespace {
                i = query.index(after: i)
            }
            if i >= query.endIndex { break }
            let start = i
            var inQuotes = false
            while i < query.endIndex {
                let c = query[i]
                if c == "\"" {
                    inQuotes.toggle()
                } else if c.isWhitespace && !inQuotes {
                    break
                }
                i = query.index(after: i)
            }
            let token = String(query[start..<i])
            if !token.isEmpty {
                tokens.append(token)
            }
        }
        return tokens
    }

    /// Returns only structured `key:value` tokens from the query where `key` is in `knownKeys`
    /// (including optional leading negation prefixes `!`, `-`, `^`).
    public static func extractStructuredTokens(from query: String, knownKeys: Set<String>) -> [String] {
        extractTokens(from: query).filter { tok in
            guard let colon = tok.firstIndex(of: ":") else { return false }
            var key = String(tok[tok.startIndex..<colon]).lowercased()
            if let first = key.first, ["!", "-", "^"].contains(first) {
                key.removeFirst()
            }
            let val = String(tok[tok.index(after: colon)...]).replacingOccurrences(of: "\"", with: "")
            return knownKeys.contains(key) && !val.isEmpty
        }
    }

    /// Normalizes a chip token for comparison (lowercased, quotes stripped).
    public static func normalizeChip(_ token: String) -> String {
        var lower = token.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lower.hasPrefix("\"") { lower.removeFirst() }
        if lower.hasSuffix("\"") { lower.removeLast() }
        return lower.replacingOccurrences(of: "\"", with: "")
    }

    /// Checks if a chip (e.g. `is:recipe`, `type:url`) is present in the search query.
    public static func isChipActive(_ chip: String, in query: String) -> Bool {
        let normTarget = normalizeChip(chip)
        guard !normTarget.isEmpty else { return false }
        let tokens = extractTokens(from: query)
        return tokens.contains { normalizeChip($0) == normTarget }
    }

    /// Prepends a chip to the query. If already present, returns the query unchanged.
    public static func prependChip(_ chip: String, to query: String) -> String {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedChip = chip.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedChip.isEmpty else { return trimmedQuery }
        if isChipActive(trimmedChip, in: trimmedQuery) {
            return trimmedQuery
        }
        if trimmedQuery.isEmpty {
            return trimmedChip
        }
        return "\(trimmedChip) \(trimmedQuery)"
    }

    /// Removes all occurrences of a chip from the query.
    public static func removeChip(_ chip: String, from query: String) -> String {
        let normTarget = normalizeChip(chip)
        guard !normTarget.isEmpty else { return query }
        let tokens = extractTokens(from: query)
        let filtered = tokens.filter { normalizeChip($0) != normTarget }
        return filtered.joined(separator: " ")
    }

    /// Toggles a chip in the query: prepends if not active, removes if active.
    /// For single-valued scope keys (`type:`), removes any existing `type:*` token before adding the new one.
    public static func toggleChip(_ chip: String, in query: String) -> String {
        if isChipActive(chip, in: query) {
            return removeChip(chip, from: query)
        }
        var base = query
        if chip.lowercased().hasPrefix("type:") {
            let tokens = extractTokens(from: base).filter { !normalizeChip($0).hasPrefix("type:") }
            base = tokens.joined(separator: " ")
        }
        return prependChip(chip, to: base)
    }
}
