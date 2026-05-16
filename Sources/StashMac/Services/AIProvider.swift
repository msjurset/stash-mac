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
    // case claude   // future — see comment on AIProvider.
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
        }
    }

    /// All registered providers, in picker / menu display order.
    static var all: [AIProvider] {
        AIProviderID.allCases.map { provider(for: $0) }
    }
}
