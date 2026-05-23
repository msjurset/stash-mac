import Foundation
import Observation

/// Reads the `stash serve` daemon's identify-worker spend from
/// `~/.stash/gemini-usage.json` so the Mac's Usage & cost view
/// can fold daemon-driven calls into the totals it shows.
///
/// Why a separate store from `GeminiUsageStore`: the local store
/// counts calls THIS Mac made (interactive identify, etc.); the
/// daemon counts calls IT made (auto-identify on sortie-ingested
/// items). Same shape, different process. Keeping them in
/// distinct stores keeps the persistence concerns separate — the
/// Settings view sums them at render time for the combined view.
///
/// Polling: file is re-read every 30s while the Settings panel
/// is open. The daemon writes atomically (tmp + rename), so a
/// concurrent read either sees the previous full snapshot or the
/// new full snapshot — never a half-written file.
@Observable
@MainActor
final class GeminiDaemonUsageStore {
    static let shared = GeminiDaemonUsageStore()

    /// Same shape as `GeminiUsageStore.Usage` so the view can
    /// render either with the same logic. `loaded` is false when
    /// the daemon hasn't written anything yet (fresh install /
    /// no identify has run) — the view hides the daemon row in
    /// that case to avoid confusing zeros.
    struct Usage: Equatable {
        var today: PerModelTotals = PerModelTotals()
        var allTime: PerModelTotals = PerModelTotals()
        var date: String = ""
        var firstSeenDate: String? = nil
        /// True when the daemon ledger file exists AND has at
        /// least one call recorded. Drives the Settings view's
        /// decision to render the "Auto-identify (daemon)" row.
        var loaded: Bool = false

        var todayCalls: Int { today.totalCalls }
        var allTimeCalls: Int { allTime.totalCalls }
        func todayCostUsd() -> Double { today.costUsd() }
        func allTimeCostUsd() -> Double { allTime.costUsd() }
    }

    var usage = Usage()

    /// Absolute path of the ledger file. Mirrors the path the
    /// daemon writes (`internal/usage`).
    static var ledgerPath: String {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".stash/gemini-usage.json")
            .path
    }

    /// Tilde-shortened display form, used in Settings fine print.
    static var ledgerDisplayPath: String { "~/.stash/gemini-usage.json" }

    private var timer: Timer?
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? URL(fileURLWithPath: Self.ledgerPath)
        reload()
    }

    /// Re-read the file. Safe to call from anywhere on the main
    /// actor; failures (missing file, malformed JSON) are silent
    /// and leave `usage.loaded = false`.
    func reload() {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else {
            usage = Usage()
            return
        }
        let dec = JSONDecoder()
        // Daemon writes snake_case (cross-platform schema). Map
        // to the camelCase properties on PerModelTotals /
        // ModelBucket automatically.
        dec.keyDecodingStrategy = .convertFromSnakeCase
        guard let raw = try? dec.decode(WireSnapshot.self, from: data) else {
            usage = Usage()
            return
        }
        let total = raw.today.totalCalls + raw.allTime.totalCalls
        usage = Usage(
            today: raw.today,
            allTime: raw.allTime,
            date: raw.date,
            firstSeenDate: raw.firstSeenDate,
            loaded: total > 0
        )
    }

    /// Start periodic refresh — called when the Settings view
    /// appears so the daemon row doesn't go stale while it's
    /// being watched. Stop via `stopPolling()` on disappear.
    func startPolling(interval: TimeInterval = 30) {
        stopPolling()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    /// Wire-level snapshot shape. The daemon's JSON uses
    /// snake_case keys with a top-level `today` / `all_time` /
    /// `date` / `first_seen_date` layout (see Go's
    /// `internal/usage.Snapshot`).
    private struct WireSnapshot: Decodable {
        var today: PerModelTotals
        var allTime: PerModelTotals
        var date: String
        var firstSeenDate: String?
    }
}
