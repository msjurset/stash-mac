import AppKit
import Foundation
import OSLog

/// Runtime detector for the phantom autofill / inline-prediction popup
/// that has historically regressed in stash-mac. Walks every visible
/// NSWindow's view tree, flags subviews whose class names look like
/// AppKit predictive-text / Writing Tools / autofill internals, and
/// reports them via OSLog + stderr so deploys can catch a recurrence
/// without depending on a human noticing.
///
/// Why this exists: the suppression stack in `FilterField.swift` +
/// `NoAutoFillWindowSetup.swift` is five layers deep and any one of
/// them being mistimed for a new presentation surface (sheet, popover,
/// programmatic-focus path) re-exposes the popup. Source diffs don't
/// catch it; only a runtime scan does. Counter + design in
/// `~/.claude/projects/.../memory/{feedback_phantom_popup_counter,
/// project_phantom_popup_test}.md`.
@MainActor
enum PhantomPopupDetector {

    /// One sighting of a suspicious view. `frame` is in window
    /// coordinates so the user can correlate with what they were
    /// looking at; `hasTextDescendants` distinguishes the empty
    /// ghost (false) from a real completion menu with content (true).
    struct Hit: Sendable, Hashable {
        let className: String
        let frame: NSRect
        let windowTitle: String
        let hasTextDescendants: Bool
    }

    /// Substring needles. Every class name that has been observed to
    /// host the phantom popup contains at least one of these. New
    /// macOS releases occasionally rename internals — when the
    /// counter ticks again, the diagnosis often points at a needle
    /// that needs adding.
    static let classNameNeedles: [String] = [
        "Prediction",
        "Completion",
        "Inline",
        "Suggestion",
        "Autofill",
        "WritingTools",
    ]

    /// One scan: walk every visible window. Returns hits in
    /// pre-order traversal across windows.
    static func snapshot() -> [Hit] {
        var hits: [Hit] = []
        for window in NSApp.windows {
            guard window.isVisible else { continue }
            walk(view: window.contentView,
                 windowTitle: window.title,
                 into: &hits)
        }
        return hits
    }

    // Below these dimensions a needle-matching view is almost
    // certainly an AppKit internal helper rather than the popup
    // surface itself — exclude to keep noise down.
    private static let minWidth: CGFloat = 80
    private static let minHeight: CGFloat = 30

    private static func walk(view: NSView?,
                             windowTitle: String,
                             into hits: inout [Hit]) {
        guard let view, !view.isHidden else { return }
        let className = NSStringFromClass(type(of: view))
        if classNameNeedles.contains(where: { className.contains($0) }) {
            let frameInWindow = view.convert(view.bounds, to: nil)
            if frameInWindow.size.width >= minWidth,
               frameInWindow.size.height >= minHeight {
                hits.append(
                    Hit(
                        className: className,
                        frame: frameInWindow,
                        windowTitle: windowTitle.isEmpty ? "<no-title>" : windowTitle,
                        hasTextDescendants: hasVisibleTextDescendants(view)
                    )
                )
            }
        }
        for sub in view.subviews {
            walk(view: sub, windowTitle: windowTitle, into: &hits)
        }
    }

    /// Real completion / suggestion menus contain visible labels with
    /// the candidate strings. The phantom ghost popup is empty inside.
    /// This isn't a perfect oracle — some macOS rev may render text
    /// via a non-NSTextField path — but it's a strong first filter
    /// for distinguishing "we have a regression" from "user clicked
    /// in a search field with real results."
    private static func hasVisibleTextDescendants(_ view: NSView) -> Bool {
        if let field = view as? NSTextField, !field.stringValue.isEmpty {
            return true
        }
        if let cell = (view as? NSControl)?.cell, !cell.stringValue.isEmpty {
            return true
        }
        for sub in view.subviews where !sub.isHidden {
            if hasVisibleTextDescendants(sub) { return true }
        }
        return false
    }

    // MARK: - Watcher

    private static let log = Logger(
        subsystem: "com.msjurseth.stash",
        category: "phantom-popup"
    )
    private static var watcherTimer: Timer?
    private static var seenSignatures: Set<String> = []
    private static var hitsObserved: [Hit] = []

    /// Begin a periodic poll. Each newly-observed hit (deduped by
    /// className + window title so the same popup doesn't spam the
    /// log on every tick) is reported once via OSLog AND to stderr
    /// with a stable prefix so a CI / Make driver can grep for it.
    static func startWatching(interval: TimeInterval = 0.5) {
        guard watcherTimer == nil else { return }
        watcherTimer = Timer.scheduledTimer(
            withTimeInterval: interval,
            repeats: true
        ) { _ in
            MainActor.assumeIsolated {
                _ = tick()
            }
        }
    }

    /// Single tick of the watcher: grab a snapshot, dedupe, log new
    /// hits. Exposed for tests / one-shot diagnostic menu items.
    @discardableResult
    static func tick() -> [Hit] {
        let scan = snapshot()
        var newHits: [Hit] = []
        for hit in scan {
            let signature = "\(hit.className)|\(hit.windowTitle)|\(hit.hasTextDescendants)"
            if seenSignatures.insert(signature).inserted {
                hitsObserved.append(hit)
                newHits.append(hit)
                report(hit)
            }
        }
        return newHits
    }

    private static func report(_ hit: Hit) {
        let line = """
            STASH_PHANTOM_POPUP_HIT class=\(hit.className) \
            window=\"\(hit.windowTitle)\" \
            frame=\(Int(hit.frame.minX)),\(Int(hit.frame.minY)) \
            \(Int(hit.frame.width))x\(Int(hit.frame.height)) \
            hasText=\(hit.hasTextDescendants)
            """
        log.error("\(line, privacy: .public)")
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    /// All hits observed since the watcher started (deduped). Used by
    /// the check-mode exit path to summarize.
    static var observedHits: [Hit] { hitsObserved }

    /// Drop every recorded hit. Useful when a diagnostic UI wants to
    /// reset before re-exercising the trigger surfaces.
    static func resetHits() {
        seenSignatures.removeAll()
        hitsObserved.removeAll()
    }
}
