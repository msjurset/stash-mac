import Foundation

/// Identification result returned by any AI provider. The whole
/// pipeline (right-click → Identify with …, store, UI) talks in this
/// shape, so adding a new provider only requires implementing the
/// `AIProvider` protocol — no callers need to change.
struct AIIdentifyResult: Equatable {
    var title: String?
    var notes: String
}

/// Plug-in surface for AI image-identification backends.
///
/// To add a new provider (e.g. Claude, OpenAI):
///   1. Create a struct conforming to `AIProvider`.
///   2. Add a case to `AIProviderID` and register it inside
///      `AIProviderRegistry.provider(for:)`.
///   3. That's it — the Settings UI's picker, the prefs store,
///      and the right-click menu pick up the new entry
///      automatically.
protocol AIProvider: Sendable {
    /// Stable, lowercase identifier — used as the persistence prefix
    /// (`ai.<id>.apiKey`, `ai.<id>.prompt`) and as the Picker tag.
    var id: AIProviderID { get }
    /// Human-readable name for the Settings picker and the right-
    /// click "Identify with <Name>" menu item.
    var displayName: String { get }
    /// First few characters of a valid key for this provider — shown
    /// as the placeholder inside the API-key field so the user has
    /// a visual cue they pasted something of the right shape.
    var keyPlaceholder: String { get }
    /// Where the user goes to mint a fresh key.
    var keyURL: URL { get }
    /// Default identify prompt for this provider. Stored in prefs on
    /// first launch and offered as a Reset target.
    var defaultPrompt: String { get }

    /// Cheap key-validity probe — implementations should send the
    /// smallest possible request that exercises authentication.
    func testKey(_ apiKey: String) async throws

    /// Send image bytes + prompt, return parsed title/notes.
    func identify(
        apiKey: String,
        bytes: Data,
        mimeType: String,
        promptText: String
    ) async throws -> AIIdentifyResult
}

/// Concrete provider IDs known to the app. New providers should be
/// added here AND in `AIProviderRegistry.provider(for:)`.
enum AIProviderID: String, CaseIterable, Codable, Hashable, Identifiable {
    case gemini
    case claude
    // case openai   // future — see comment on AIProvider.

    var id: String { rawValue }
}

/// Factory that maps an `AIProviderID` to its concrete
/// implementation. Centralised so the rest of the codebase can stay
/// provider-agnostic — only this function needs editing when new
/// providers come online.
enum AIProviderRegistry {
    static func provider(for id: AIProviderID) -> AIProvider {
        switch id {
        case .gemini:
            return GeminiProvider()
        case .claude:
            return ClaudeProvider()
        }
    }

    /// All registered providers, in picker / menu display order.
    static var all: [AIProvider] {
        AIProviderID.allCases.map { provider(for: $0) }
    }
}

// MARK: - Shared defaults

/// Shared default identify prompt — same shape (TITLE: / NOTES:)
/// across providers so the Mac response parser works on any of
/// them. Mirrors the Android client's default for cross-device
/// consistency. Per-provider overrides live in `AIPrefsStore`.
enum AIPrompts {
    static let defaultIdentify: String = """
Identify the main subject in this photo.

Respond with exactly these two lines, no preamble, no markdown:

TITLE: <common name; include scientific name in parentheses when applicable>
NOTES: <natural prose, three to six sentences. Open by naming the subject in plain language — e.g. "This is the YYYY mushroom (Scientificus nameus), also known as XXXX..." or "This is the eastern bluebird (Sialia sialis), a small thrush native to..." Then cover, where relevant: notable visual characteristics; habitat, range, or season; edibility / toxicity / safety; species commonly confused with it; what specific features visible in this photo helped identify it; and any other interesting facts a curious naturalist would want to know. Be generous with detail — the user will trim what they don't want.>

If you can't identify confidently, write TITLE: Unknown and explain your best guess and the reasoning in NOTES.
"""
}

// MARK: - Shared response parsing

/// Robust title/notes extractor shared by every provider. Handles:
///   - explicit "TITLE: ..." / "NOTES: ..." (the format the default
///     prompt asks for)
///   - "Common Name: ..." / "Description: ..." natural fallback
///   - markdown wrappers (`**TITLE:**`)
///
/// If no title marker matches, title returns nil and the entire
/// response goes in notes.
enum AIResponseParser {
    static func parse(_ raw: String) -> AIIdentifyResult {
        let titleMarkers = ["TITLE", "Title", "Common Name", "Common name", "Name", "Subject"]
        let notesMarkers = ["NOTES", "Notes", "Description", "Details"]

        let lines = raw.components(separatedBy: "\n")
        var title: String? = nil
        var notes: String? = nil

        for line in lines {
            if title == nil, let val = extractValue(line, markers: titleMarkers) {
                title = val.cleanInlineMarkers()
            }
            if notes == nil, let val = extractValue(line, markers: notesMarkers) {
                notes = val.cleanInlineMarkers()
            }
            if title != nil && notes != nil { break }
        }

        let notesText: String
        if let n = notes {
            notesText = n
        } else {
            let filtered = lines.filter { line in
                extractValue(line, markers: titleMarkers) == nil
            }
            let joined = filtered.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            notesText = joined.isEmpty ? raw : joined
        }

        return AIIdentifyResult(
            title: title?.isEmpty == false ? title : nil,
            notes: notesText
        )
    }

    private static func extractValue(_ line: String, markers: [String]) -> String? {
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        let stripped = String(trimmed).trimmingCharacters(in: CharacterSet(charactersIn: "*_ "))
        for m in markers {
            let needle = "\(m):"
            if let r = stripped.range(of: needle, options: [.caseInsensitive, .anchored]) {
                let value = String(stripped[r.upperBound...])
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "*_"))
                    .trimmingCharacters(in: .whitespaces)
                return value
            }
        }
        return nil
    }
}

extension String {
    /// Strip leading/trailing markdown bold/italic markers off a
    /// single value — the model occasionally wraps the value even
    /// when asked for plain text.
    func cleanInlineMarkers() -> String {
        var s = trimmingCharacters(in: .whitespaces)
        for marker in ["**", "__", "*", "_"] {
            if s.hasPrefix(marker) && s.hasSuffix(marker) && s.count > marker.count * 2 {
                let start = s.index(s.startIndex, offsetBy: marker.count)
                let end = s.index(s.endIndex, offsetBy: -marker.count)
                s = String(s[start..<end]).trimmingCharacters(in: .whitespaces)
            }
        }
        return s
    }
}
