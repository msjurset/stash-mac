import Foundation
import SwiftUI

/// User-editable preferences for the Mac-side Gemini integration.
/// Stored in `UserDefaults` (the Mac is a single-user trust domain —
/// no need for Keychain ceremony here).
///
/// Two values:
///   - `apiKey`: Google AI Studio key. Empty disables the action.
///   - `promptText`: editable identification prompt. Defaults to
///     `GeminiDefaultPrompt.value`; "Reset to default" restores.
@Observable
@MainActor
final class GeminiPrefsStore {
    private let keyDefaults = "stashGeminiKey"
    private let promptDefaults = "stashGeminiPrompt"

    private(set) var apiKey: String
    private(set) var promptText: String

    init() {
        self.apiKey = UserDefaults.standard.string(forKey: keyDefaults) ?? ""
        self.promptText = UserDefaults.standard.string(forKey: promptDefaults)
            ?? GeminiDefaultPrompt.value
    }

    func setKey(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        apiKey = trimmed
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: keyDefaults)
        } else {
            UserDefaults.standard.set(trimmed, forKey: keyDefaults)
        }
    }

    func setPrompt(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            resetPrompt()
        } else {
            promptText = trimmed
            UserDefaults.standard.set(trimmed, forKey: promptDefaults)
        }
    }

    func resetPrompt() {
        promptText = GeminiDefaultPrompt.value
        UserDefaults.standard.removeObject(forKey: promptDefaults)
    }

    var hasKey: Bool { !apiKey.isEmpty }
}
