import AppKit
import Quartz
import SwiftUI

/// Once-and-for-all suppression of the empty rounded-rectangle popup
/// that appears the first time any field-editor or menu surface
/// initializes in a window on macOS 15. The popup is whatever
/// predictive-text / Apple Intelligence subsystem AppKit warms up when
/// it first creates the window's shared field editor — by providing
/// our own pre-configured editor *before* AppKit gets a chance to
/// instantiate the default one, the warm-up has nothing to render.
///
/// The interception happens via NSWindowDelegate's
/// `windowWillReturnFieldEditor(_:to:)` — when that returns non-nil,
/// AppKit uses it in place of its own default editor. SwiftUI assigns
/// its own internal delegate to the windows it creates, so we wrap
/// that delegate via a forwarding NSObject (`responds(to:)` +
/// `forwardingTarget(for:)`) and only add this single method on top.
/// Everything SwiftUI's delegate did before still happens; we just
/// inject one extra hook.

/// The pre-configured field editor returned by every wrapped window.
/// One per app — NSText/NSTextView field editors are designed to be
/// shared; AppKit checks that the returned editor isn't already in
/// use elsewhere and falls back to its own pool when it is, so a
/// shared instance plus the same disabled flags is the canonical
/// shape.
@MainActor
private let sharedNoAutoFillFieldEditor: NSTextView = {
    let editor = NSTextView()
    editor.isFieldEditor = true
    configureNoAutoFill(editor)
    return editor
}()

@MainActor
private func configureNoAutoFill(_ editor: NSTextView) {
    editor.isAutomaticTextCompletionEnabled = false
    editor.isAutomaticSpellingCorrectionEnabled = false
    editor.isAutomaticTextReplacementEnabled = false
    editor.isContinuousSpellCheckingEnabled = false
    editor.isAutomaticQuoteSubstitutionEnabled = false
    editor.isAutomaticDashSubstitutionEnabled = false
    editor.isAutomaticDataDetectionEnabled = false
    editor.isAutomaticLinkDetectionEnabled = false
    if #available(macOS 14.0, *) {
        editor.inlinePredictionType = .no
    }
    if #available(macOS 15.0, *) {
        editor.writingToolsBehavior = .none
        editor.allowedWritingToolsResultOptions = []
    }
}

/// Forwarding NSObject that wraps an existing NSWindowDelegate and
/// adds `windowWillReturnFieldEditor`. All other delegate calls are
/// forwarded transparently so SwiftUI's window machinery (drag, key
/// equivalents, restoration, etc.) keeps working.
final class FieldEditorInterceptor: NSObject, NSWindowDelegate {
    weak var wrapped: NSObject?

    init(wrapping wrapped: NSObject?) {
        self.wrapped = wrapped
        super.init()
    }

    /// Tell AppKit we respond to a selector if EITHER we implement it
    /// directly, or the wrapped delegate does. Without this AppKit
    /// won't even attempt forwarding for selectors we don't define.
    override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) { return true }
        return wrapped?.responds(to: aSelector) ?? false
    }

    /// Route any selector this interceptor doesn't define to the
    /// wrapped delegate. Selectors we DO define (notably
    /// windowWillReturnFieldEditor) get handled here.
    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        guard let wrapped, wrapped.responds(to: aSelector) else { return nil }
        return wrapped
    }

    @MainActor
    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        // Re-apply flags every time AppKit asks for the editor — some
        // of these are reset between editor uses, and Sequoia in
        // particular re-enables `inlinePredictionType` on reuse.
        configureNoAutoFill(sharedNoAutoFillFieldEditor)
        return sharedNoAutoFillFieldEditor
    }
}

/// Strong references to installed interceptors, keyed by window
/// identity. Without this the wrapped objects would dealloc as soon
/// as `installFieldEditorInterceptor` returns since NSWindow.delegate
/// is a weak reference.
@MainActor
private var installedInterceptors: [ObjectIdentifier: FieldEditorInterceptor] = [:]

/// Heuristic class-name fragments that identify AppKit predictive /
/// Writing-Tools / inline-suggestion panels. Match is substring
/// `contains`-based since Apple namespaces these with private
/// underscore-prefixed classes and the exact names vary by macOS
/// version. False positives would orderOut some other AppKit panel
/// but the fragments are specific enough — "InlinePrediction",
/// "WritingTools", "InlineSuggestion", "PredictionPanel" — that no
/// legitimate panel in our app would match.
@MainActor
private let predictivePanelFragments: [String] = [
    "InlinePrediction",
    "InlineSuggestion",
    "PredictionPanel",
    "WritingTools",
    "TextCompletion",
    // macOS 26's empty-rounded autofill popup — confirmed via
    // reaper diagnostics (~/.recruit/reaper.log). Animates from
    // ~312×237 to ~332×265 right after a layout change (cold
    // launch or console expand). The "SP" prefix isn't Sparkle —
    // Sparkle uses SU/SPU. This is the system predictive surface
    // that none of the documented per-editor flags suppress.
    "SPRoundedWindow",
]

/// Order-out any visible panel whose class name matches a known
/// predictive-text fragment. Cheap to call (NSApp.windows is small)
/// and idempotent so multiple triggers per second are fine.
///
/// Diagnostic mode: when `verbose` is true, also logs the class
/// name of every visible window — used to identify new predictive
/// panel variants on macOS upgrades. Tap into this by setting the
/// flag below; output goes to stderr so it shows up under
/// `make deploy` console / Console.app.
@MainActor
private let reaperLogPath: String = {
    // Always-on diagnostic file at a known path so the user
    // doesn't need to mess with stderr redirection. Truncated on
    // app launch via O_TRUNC equivalent so the log reflects only
    // the current session.
    let path = NSHomeDirectory() + "/.stash/reaper.log"
    try? "".write(toFile: path, atomically: true, encoding: .utf8)
    return path
}()

@MainActor
private func reapLog(_ s: String) {
    let line = s + "\n"
    if let h = try? FileHandle(forWritingTo: URL(fileURLWithPath: reaperLogPath)) {
        h.seekToEndOfFile()
        h.write(Data(line.utf8))
        try? h.close()
    } else {
        // First call: file may have been deleted; recreate.
        try? line.write(toFile: reaperLogPath, atomically: true, encoding: .utf8)
    }
}

@MainActor
func reapPredictivePanels() {
    for window in NSApp.windows where window.isVisible {
        let name = NSStringFromClass(type(of: window))
        if predictivePanelFragments.contains(where: { name.contains($0) }) {
            reapLog("[reaper] KILLED \(name) frame=\(window.frame)")
            window.orderOut(nil)
        }
    }
}

/// Install (or replace) the interceptor on a window. Idempotent —
/// safe to call repeatedly when SwiftUI re-assigns the delegate.
@MainActor
func installFieldEditorInterceptor(on window: NSWindow) {
    let key = ObjectIdentifier(window)
    let currentDelegate = window.delegate as? NSObject
    // If we've already wrapped this window's current delegate, leave it
    // alone. Detect by checking whether the current delegate IS our
    // interceptor for this window.
    if let existing = installedInterceptors[key],
       window.delegate === existing {
        return
    }
    let interceptor = FieldEditorInterceptor(wrapping: currentDelegate)
    installedInterceptors[key] = interceptor
    window.delegate = interceptor
}


