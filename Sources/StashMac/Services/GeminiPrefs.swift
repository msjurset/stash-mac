import Foundation
import SwiftUI

/// User-editable preferences for the Mac-side AI integrations.
/// Provider-aware: each registered `AIProvider` keeps its own key
/// and prompt, and the user picks which one is active. The active
/// provider's settings drive the right-click "Identify with …"
/// action.
///
/// Stored in `UserDefaults` (the Mac is a single-user trust domain
/// — no need for Keychain ceremony here). The persistence keys are
/// scoped per-provider so they can co-exist:
///
///   - `ai.activeProvider`        → raw value of `AIProviderID`
///   - `ai.<id>.apiKey`           → API key
///   - `ai.<id>.prompt`           → editable identify prompt
///
/// Legacy single-provider keys (`stashGeminiKey`, `stashGeminiPrompt`)
/// are migrated transparently on first launch after the upgrade so
/// users don't have to re-paste their key.
@Observable
@MainActor
final class AIPrefsStore {
    private(set) var activeID: AIProviderID
    private var apiKeys: [AIProviderID: String]
    private var prompts: [AIProviderID: String]

    var activeProvider: AIProvider { AIProviderRegistry.provider(for: activeID) }
    var apiKey: String { apiKeys[activeID] ?? "" }
    var promptText: String { prompt(for: activeID) }
    var hasKey: Bool { !apiKey.isEmpty }

    private let defaults = UserDefaults.standard
    private let activeKey = "ai.activeProvider"
    // Legacy single-provider keys preserved for one-shot migration.
    private let legacyKeyKey = "stashGeminiKey"
    private let legacyPromptKey = "stashGeminiPrompt"

    init() {
        // Active provider — default to Gemini if unset or unknown.
        if let raw = UserDefaults.standard.string(forKey: "ai.activeProvider"),
           let parsed = AIProviderID(rawValue: raw) {
            self.activeID = parsed
        } else {
            self.activeID = .gemini
        }

        // Per-provider storage. Read every provider so the user can
        // flip the picker without losing any pre-configured keys.
        var keys: [AIProviderID: String] = [:]
        var prompts: [AIProviderID: String] = [:]
        for id in AIProviderID.allCases {
            keys[id] = UserDefaults.standard.string(forKey: "ai.\(id.rawValue).apiKey") ?? ""
            prompts[id] = UserDefaults.standard.string(forKey: "ai.\(id.rawValue).prompt") ?? ""
        }
        self.apiKeys = keys
        self.prompts = prompts

        // One-shot migration from the previous single-provider keys.
        migrateLegacyIfNeeded()
    }

    private func migrateLegacyIfNeeded() {
        if (apiKeys[.gemini] ?? "").isEmpty,
           let legacy = defaults.string(forKey: legacyKeyKey),
           !legacy.isEmpty {
            apiKeys[.gemini] = legacy
            defaults.set(legacy, forKey: "ai.gemini.apiKey")
            defaults.removeObject(forKey: legacyKeyKey)
        }
        if (prompts[.gemini] ?? "").isEmpty,
           let legacy = defaults.string(forKey: legacyPromptKey),
           !legacy.isEmpty {
            prompts[.gemini] = legacy
            defaults.set(legacy, forKey: "ai.gemini.prompt")
            defaults.removeObject(forKey: legacyPromptKey)
        }
    }

    /// Switch the active provider. The Settings UI re-reads `apiKey`
    /// / `promptText` afterwards so the editor fields reflect the
    /// newly-selected provider's stored values.
    func setActiveProvider(_ id: AIProviderID) {
        activeID = id
        defaults.set(id.rawValue, forKey: activeKey)
    }

    func setKey(_ value: String, for id: AIProviderID? = nil) {
        // Strip surrounding quotes and whitespace — pasting an
        // op:// reference from a code sample often drags quotes
        // along, and surrounding quotes are never valid in any
        // real key format we accept.
        let cleaned = AIKeyResolver.clean(value)
        let target = id ?? activeID
        apiKeys[target] = cleaned
        if cleaned.isEmpty {
            defaults.removeObject(forKey: "ai.\(target.rawValue).apiKey")
        } else {
            defaults.set(cleaned, forKey: "ai.\(target.rawValue).apiKey")
        }
    }

    func setPrompt(_ value: String, for id: AIProviderID? = nil) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = id ?? activeID
        if trimmed.isEmpty {
            resetPrompt(for: target)
        } else {
            prompts[target] = trimmed
            defaults.set(trimmed, forKey: "ai.\(target.rawValue).prompt")
        }
    }

    func resetPrompt(for id: AIProviderID? = nil) {
        let target = id ?? activeID
        prompts[target] = AIProviderRegistry.provider(for: target).defaultPrompt
        defaults.removeObject(forKey: "ai.\(target.rawValue).prompt")
    }

    /// Per-provider accessor used by the Settings UI when displaying
    /// the not-currently-active providers (e.g. so swapping the
    /// picker reveals each provider's pre-configured key).
    func apiKey(for id: AIProviderID) -> String { apiKeys[id] ?? "" }
    /// Falls back to the provider's default prompt when nothing is
    /// stored OR when the stored value is empty (the migration path
    /// fills the dict with empty strings for every provider before
    /// pulling from UserDefaults, so a plain dict lookup would skip
    /// the fallback).
    func prompt(for id: AIProviderID) -> String {
        let stored = prompts[id] ?? ""
        return stored.isEmpty
            ? AIProviderRegistry.provider(for: id).defaultPrompt
            : stored
    }
}
