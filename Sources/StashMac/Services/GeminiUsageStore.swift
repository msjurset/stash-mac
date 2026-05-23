import Foundation
import Observation

/// Tracks Gemini API call counts + input/output token totals so
/// the user can see what the app is actually spending against
/// their quota and (paid) billing. UserDefaults-backed — non-
/// sensitive, small, persistent across launches.
///
/// Today's counter rolls over automatically when the stored date
/// no longer matches the current local date. All-time counter
/// never resets (until the user hits "Reset all-time" in
/// Settings).
///
/// Input vs output tokens are tracked separately because Gemini
/// bills them at different rates — see `GeminiPricing`. Cost
/// calculations live on the snapshot; the forecaster uses the
/// daily average since `firstSeenDate` to project monthly burn,
/// so the user can spot a runaway-cost trajectory before it
/// lands on the credit card.
///
/// Mirrors the Android `GeminiUsageStore` so both clients
/// surface the same view of what's being spent.
/// Per-model usage bucket: calls + input/output tokens for one
/// model. The store maps model name → ModelBucket so a session
/// that calls both 2.5-flash (default) AND falls back to 2.5-pro
/// (rare) records each at the right rate and the cost projection
/// stays accurate.
struct ModelBucket: Codable, Equatable {
    var calls: Int = 0
    var inputTokens: Int64 = 0
    var outputTokens: Int64 = 0
}

/// Sum of buckets, plus convenience views over the totals. Cost
/// is computed per-model and summed, so each model's tokens get
/// its own rate.
struct PerModelTotals: Codable, Equatable {
    var byModel: [String: ModelBucket] = [:]

    var totalCalls: Int {
        byModel.values.reduce(0) { $0 + $1.calls }
    }
    var totalInputTokens: Int64 {
        byModel.values.reduce(0) { $0 + $1.inputTokens }
    }
    var totalOutputTokens: Int64 {
        byModel.values.reduce(0) { $0 + $1.outputTokens }
    }

    /// Total cost in USD, summing each model's contribution at
    /// that model's published rate. This is the load-bearing fix
    /// for forecast accuracy when calls fan out across models
    /// (a future identify-fallback chain that uses pro on
    /// hard-to-identify images would otherwise be billed at
    /// flash rates and undershoot).
    func costUsd() -> Double {
        byModel.reduce(0.0) { acc, kv in
            acc + GeminiPricing.costUsd(
                inputTokens: kv.value.inputTokens,
                outputTokens: kv.value.outputTokens,
                model: kv.key
            )
        }
    }

    mutating func add(model: String, inputDelta: Int64, outputDelta: Int64) {
        var b = byModel[model] ?? ModelBucket()
        b.calls += 1
        b.inputTokens += inputDelta
        b.outputTokens += outputDelta
        byModel[model] = b
    }
}

@Observable
@MainActor
final class GeminiUsageStore {
    /// Process-wide shared instance. Identify call sites can't
    /// easily thread a per-call store reference through (the
    /// AIProvider protocol is intentionally provider-agnostic),
    /// so the Gemini HTTP layer dispatches usage records here.
    /// Tests can construct their own instance instead.
    static let shared = GeminiUsageStore()

    struct Usage: Equatable {
        var today: PerModelTotals = PerModelTotals()
        var allTime: PerModelTotals = PerModelTotals()
        var date: String = ""
        /// First-tracked day on this Mac (ISO yyyy-MM-dd) — used
        /// to amortize the all-time totals into a per-day average
        /// for the forecaster. Nil = "no history yet."
        var firstSeenDate: String? = nil

        // Convenience flat views over today's bucket — the Settings
        // UI was written against these before the per-model
        // refactor; keeping them as derived getters means the
        // existing rows render unchanged.
        var todayCalls: Int { today.totalCalls }
        var todayInputTokens: Int64 { today.totalInputTokens }
        var todayOutputTokens: Int64 { today.totalOutputTokens }
        var allTimeCalls: Int { allTime.totalCalls }
        var allTimeInputTokens: Int64 { allTime.totalInputTokens }
        var allTimeOutputTokens: Int64 { allTime.totalOutputTokens }

        var todayTokens: Int64 { todayInputTokens + todayOutputTokens }
        var allTimeTokens: Int64 { allTimeInputTokens + allTimeOutputTokens }

        func todayCostUsd() -> Double { today.costUsd() }
        func allTimeCostUsd() -> Double { allTime.costUsd() }

        /// Daily burn average USD, computed from all-time totals
        /// over the days the user has been tracking. Returns 0
        /// when history is empty.
        func dailyAverageUsd() -> Double {
            guard let first = firstSeenDate else { return 0 }
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withFullDate]
            guard let a = f.date(from: first),
                  let b = f.date(from: date) else { return allTimeCostUsd() }
            let days = max(1.0, b.timeIntervalSince(a) / 86_400)
            return allTimeCostUsd() / days
        }

        /// 30-day projection USD — daily burn × 30. Spot a
        /// runaway cost trajectory before the credit card bill
        /// arrives.
        func thirtyDayProjectionUsd() -> Double { dailyAverageUsd() * 30 }
    }

    var usage = Usage()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        migrateLegacyCombinedTokens()
        self.usage = snapshot()
    }

    /// Record one Gemini call against a specific model. Nil token
    /// counts (response carried no usageMetadata) count as zero.
    /// The model name routes the contribution into its own
    /// bucket so cost = Σ tokens × that model's rate.
    func record(model: String, promptTokens: Int?, candidateTokens: Int?) {
        let today = Self.todayString()
        let storedDate = defaults.string(forKey: Keys.date)
        let sameDay = storedDate == today

        let inputDelta = Int64(promptTokens ?? 0)
        let outputDelta = Int64(candidateTokens ?? 0)

        // Load current buckets (today's bucket resets at midnight).
        var todayTotals: PerModelTotals = sameDay
            ? loadPerModel(forKey: Keys.todayByModel) ?? PerModelTotals()
            : PerModelTotals()
        var allTotals: PerModelTotals = loadPerModel(forKey: Keys.allByModel) ?? PerModelTotals()

        todayTotals.add(model: model, inputDelta: inputDelta, outputDelta: outputDelta)
        allTotals.add(model: model, inputDelta: inputDelta, outputDelta: outputDelta)

        let firstSeen = defaults.string(forKey: Keys.firstSeen) ?? today

        defaults.set(today, forKey: Keys.date)
        savePerModel(todayTotals, forKey: Keys.todayByModel)
        savePerModel(allTotals, forKey: Keys.allByModel)
        defaults.set(firstSeen, forKey: Keys.firstSeen)

        usage = Usage(
            today: todayTotals,
            allTime: allTotals,
            date: today,
            firstSeenDate: firstSeen
        )
    }

    func resetAllTime() {
        defaults.removeObject(forKey: Keys.allByModel)
        defaults.removeObject(forKey: Keys.firstSeen)
        usage = snapshot()
    }

    private func snapshot() -> Usage {
        let today = Self.todayString()
        let storedDate = defaults.string(forKey: Keys.date)
        let sameDay = storedDate == today
        let todayTotals: PerModelTotals = sameDay
            ? loadPerModel(forKey: Keys.todayByModel) ?? PerModelTotals()
            : PerModelTotals()
        let allTotals: PerModelTotals = loadPerModel(forKey: Keys.allByModel) ?? PerModelTotals()
        return Usage(
            today: todayTotals,
            allTime: allTotals,
            date: today,
            firstSeenDate: defaults.string(forKey: Keys.firstSeen)
        )
    }

    /// One-shot forward migration: earlier versions of this store
    /// stored separate `today_calls / today_input / today_output`
    /// scalar keys (combined across all models). Move whatever's
    /// there into the default-model bucket so the user's history
    /// isn't lost, then delete the legacy keys.
    private func migrateLegacyCombinedTokens() {
        let needsMigration = defaults.object(forKey: Keys.legacyAllCalls) != nil
        guard needsMigration else { return }
        let defaultModel = GeminiPricing.defaultModel
        var allTotals = PerModelTotals()
        let legacyCalls = defaults.integer(forKey: Keys.legacyAllCalls)
        let legacyInput = Int64(defaults.integer(forKey: Keys.legacyAllInput))
        let legacyOutput = Int64(defaults.integer(forKey: Keys.legacyAllOutput))
        if legacyCalls > 0 || legacyInput > 0 || legacyOutput > 0 {
            allTotals.byModel[defaultModel] = ModelBucket(
                calls: legacyCalls,
                inputTokens: legacyInput,
                outputTokens: legacyOutput
            )
            savePerModel(allTotals, forKey: Keys.allByModel)
        }
        // Today's bucket — only migrate if same day, otherwise
        // discard (today rolls over anyway).
        let today = Self.todayString()
        if defaults.string(forKey: Keys.date) == today {
            let tCalls = defaults.integer(forKey: Keys.legacyTodayCalls)
            let tInput = Int64(defaults.integer(forKey: Keys.legacyTodayInput))
            let tOutput = Int64(defaults.integer(forKey: Keys.legacyTodayOutput))
            if tCalls > 0 || tInput > 0 || tOutput > 0 {
                var todayTotals = PerModelTotals()
                todayTotals.byModel[defaultModel] = ModelBucket(
                    calls: tCalls,
                    inputTokens: tInput,
                    outputTokens: tOutput
                )
                savePerModel(todayTotals, forKey: Keys.todayByModel)
            }
        }
        // Drop the old keys so we don't migrate twice.
        for k in [
            Keys.legacyTodayCalls, Keys.legacyTodayInput, Keys.legacyTodayOutput,
            Keys.legacyAllCalls, Keys.legacyAllInput, Keys.legacyAllOutput,
        ] {
            defaults.removeObject(forKey: k)
        }
    }

    private func loadPerModel(forKey key: String) -> PerModelTotals? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PerModelTotals.self, from: data)
    }

    private func savePerModel(_ totals: PerModelTotals, forKey key: String) {
        if let data = try? JSONEncoder().encode(totals) {
            defaults.set(data, forKey: key)
        }
    }

    private static func todayString() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f.string(from: Date())
    }

    private enum Keys {
        static let date = "gemini.usage.date"
        static let todayByModel = "gemini.usage.today.byModel"
        static let allByModel = "gemini.usage.all.byModel"
        static let firstSeen = "gemini.usage.first.seen"
        // Legacy v1 keys — read on migration, never written.
        static let legacyTodayCalls = "gemini.usage.today.calls"
        static let legacyTodayInput = "gemini.usage.today.input"
        static let legacyTodayOutput = "gemini.usage.today.output"
        static let legacyAllCalls = "gemini.usage.all.calls"
        static let legacyAllInput = "gemini.usage.all.input"
        static let legacyAllOutput = "gemini.usage.all.output"
    }
}

/// Gemini paid-tier pricing — USD per million tokens, by model.
/// Numbers sourced from GCP's billing pricing export
/// ("Pricing for My Billing Account.csv"), late 2025.
///
/// **Loaded from `~/.stash/gemini-pricing.json`** so the user can
/// update rates when Google ships changes without rebuilding the
/// app. The first time the file is missing, the compiled defaults
/// below are written to disk so there's something to edit. The
/// loader merges file-provided rates ON TOP of the compiled
/// defaults — a future Stash build that adds a new model (e.g.
/// Gemini 4 Pro) brings it in via compiled defaults even if the
/// user's hand-edited file doesn't mention it.
///
/// File schema:
///   {
///     "models": {
///       "gemini-2.5-flash": { "input_per_million": 0.30, "output_per_million": 2.50 },
///       ...
///     },
///     "default_model": "gemini-2.5-flash"
///   }
enum GeminiPricing {
    struct Rate: Codable, Equatable {
        let inputPerMillion: Double
        let outputPerMillion: Double
        enum CodingKeys: String, CodingKey {
            case inputPerMillion = "input_per_million"
            case outputPerMillion = "output_per_million"
        }
    }

    private struct Catalog: Codable {
        var models: [String: Rate]
        var defaultModel: String?
        enum CodingKeys: String, CodingKey {
            case models
            case defaultModel = "default_model"
        }
    }

    /// Compiled-in safety net. Used when the on-disk catalog is
    /// missing, corrupt, or doesn't mention a particular model.
    private static let compiledDefaults = Catalog(
        models: [
            "gemini-2.5-flash":      Rate(inputPerMillion: 0.30,  outputPerMillion: 2.50),
            "gemini-2.5-flash-lite": Rate(inputPerMillion: 0.10,  outputPerMillion: 0.40),
            "gemini-2.5-pro":        Rate(inputPerMillion: 1.25,  outputPerMillion: 10.00),
            "gemini-3-flash":        Rate(inputPerMillion: 0.50,  outputPerMillion: 3.00),
            "gemini-3-pro":          Rate(inputPerMillion: 2.00,  outputPerMillion: 12.00),
        ],
        defaultModel: "gemini-2.5-flash"
    )

    /// Effective catalog — compiled defaults overlaid with any
    /// rates from the on-disk JSON. Lazy: loaded on first access,
    /// reload via `reload()`. Marked nonisolated(unsafe) because
    /// Swift 6 strict concurrency flags a mutable static; in
    /// practice writes happen only at first access (lazy init) and
    /// on explicit `reload()` (user-triggered, main thread), while
    /// reads are everywhere. A torn read at the moment of reload
    /// would just yield slightly stale rates for one tick.
    nonisolated(unsafe) private static var loaded: Catalog = load()

    static var rates: [String: Rate] { loaded.models }

    /// Default model — file can override; otherwise falls back
    /// to the compiled-in default.
    static var defaultModel: String {
        loaded.defaultModel ?? compiledDefaults.defaultModel ?? "gemini-2.5-flash"
    }

    static func rate(for model: String) -> Rate {
        loaded.models[model]
            ?? loaded.models[defaultModel]
            ?? compiledDefaults.models["gemini-2.5-flash"]!
    }

    static func costUsd(inputTokens: Int64, outputTokens: Int64, model: String? = nil) -> Double {
        let r = rate(for: model ?? defaultModel)
        return Double(inputTokens) / 1_000_000 * r.inputPerMillion
            + Double(outputTokens) / 1_000_000 * r.outputPerMillion
    }

    /// Re-read `~/.stash/gemini-pricing.json` from disk. Call this
    /// from Settings → "Reload pricing" if you want to apply edits
    /// without restarting the app. Cheap (a JSON parse), so safe
    /// to call freely.
    static func reload() {
        loaded = load()
    }

    /// Absolute path of the pricing file. Surfaced so the
    /// Settings UI can show "Edit at /Users/you/.stash/…" — gives
    /// the user a clear anchor for where to make changes.
    static var configFilePath: String { configURL.path }

    /// Tilde-shortened display form, e.g. `~/.stash/gemini-pricing.json`.
    /// Used in fine-print footers where the absolute path would
    /// be visually noisy and the relative form is universally
    /// recognizable.
    static var configFileDisplayPath: String {
        let home = NSHomeDirectory()
        let abs = configURL.path
        return abs.hasPrefix(home) ? "~" + abs.dropFirst(home.count) : abs
    }

    private static let configURL: URL = {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".stash/gemini-pricing.json")
    }()

    private static func load() -> Catalog {
        var merged = compiledDefaults.models
        var resolvedDefault: String? = compiledDefaults.defaultModel
        let fm = FileManager.default
        if fm.fileExists(atPath: configURL.path) {
            do {
                let data = try Data(contentsOf: configURL)
                let parsed = try JSONDecoder().decode(Catalog.self, from: data)
                // Overlay file-provided rates onto compiled
                // defaults. File can specify a subset; missing
                // models keep the built-in rate so a stale file
                // doesn't make a new model invisible.
                for (k, v) in parsed.models { merged[k] = v }
                if let d = parsed.defaultModel { resolvedDefault = d }
            } catch {
                NSLog(
                    "[GeminiPricing] failed to load %@: %@ — using compiled defaults",
                    configURL.path, error.localizedDescription
                )
            }
        } else {
            // First run — write the compiled defaults so the user
            // has a file template to edit. Best-effort; if the
            // write fails we just keep using the in-memory copy.
            writeDefaultsIfMissing()
        }
        return Catalog(models: merged, defaultModel: resolvedDefault)
    }

    private static func writeDefaultsIfMissing() {
        let dir = configURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(compiledDefaults) {
            try? data.write(to: configURL, options: [.atomic])
        }
    }
}
