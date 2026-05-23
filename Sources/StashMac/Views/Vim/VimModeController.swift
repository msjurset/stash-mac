import SwiftUI
import AppKit
import VimEngine

extension Notification.Name {
    /// Posted when any VimHostEditor's vim state changes.
    /// `userInfo["active"]` carries the new state as Bool. Used by
    /// app-level Esc / keyboard monitors that need to yield to vim
    /// while it's on. Mirrors jrnlbar's `vimStateChanged`.
    public static let vimStateChanged = Notification.Name("vimStateChanged")
}

/// Owns the VimEngine lifecycle for a single editor. Each
/// VimHostEditor call site instantiates one via `@State` (or
/// passes one in if the parent wants to control activation
/// externally). Centralizes the wiring: engine creation,
/// `onExit` / `onSubmit` / `onSubmodeChanged` /
/// `onCommandBufferChanged` callbacks, badge text, and the
/// vimStateChanged broadcast.
///
/// Why @Observable: SwiftUI views observe `engine`, `currentMode`,
/// and `badgeText` to refresh the editor + badge UI. Plain class
/// with @Observable gives us reference semantics (closures captured
/// by the engine see the latest state) while still triggering
/// SwiftUI updates.
@Observable
@MainActor
final class VimModeController {
    /// Active engine when vim is on; nil otherwise.
    var engine: VimEngine?
    /// Mirror of `engine != nil`, also stored explicitly so the
    /// editor can branch behavior even if it doesn't read engine
    /// directly.
    var currentMode: EditorMode?
    /// Cached `engine.badge`. Updated on submode / command-buffer
    /// callbacks. Surfaced by VimModeBadge.
    var badgeText: String = "VIM:N"
    /// Whether the cheatsheet popover is open. Bound to the help
    /// button next to the badge.
    var showCheatsheet: Bool = false

    /// Caller-provided "save" handler — invoked when vim runs
    /// `:w` or `:wq`. nil = no save semantics; `:w` is a no-op,
    /// `:wq` exits without saving.
    var onSubmit: (() -> Void)?

    /// Activate vim. Idempotent — re-activating while already in
    /// vim mode is a no-op (matches the "/vim toggles off" path
    /// at the SlashCommand layer; this method only enters).
    func activate() {
        guard engine == nil else { return }
        let e = VimEngine()
        e.onExit = { [weak self] in
            Task { @MainActor in self?.exit() }
        }
        e.onSubmit = { [weak self] in
            Task { @MainActor in self?.onSubmit?() }
        }
        let refresh: () -> Void = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.badgeText = self.engine?.badge ?? "VIM:N"
            }
        }
        e.onSubmodeChanged = refresh
        e.onCommandBufferChanged = refresh
        badgeText = e.badge
        engine = e
        currentMode = .vim
        broadcast(active: true)
    }

    /// Exit vim. Safe to call when already inactive; the broadcast
    /// only fires when there's a real transition.
    func exit() {
        let wasActive = (currentMode == .vim)
        engine = nil
        currentMode = nil
        showCheatsheet = false
        if wasActive {
            broadcast(active: false)
        }
    }

    /// Toggle — convenience for the `/vim` slash command commit
    /// path, which should re-type `/vim` to exit.
    func toggle() {
        if currentMode == .vim {
            exit()
        } else {
            activate()
        }
    }

    private func broadcast(active: Bool) {
        NotificationCenter.default.post(
            name: .vimStateChanged,
            object: nil,
            userInfo: ["active": active]
        )
    }
}
