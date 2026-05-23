import Foundation
import Observation

/// Lightweight transient-message HUD. AppKit-triggered actions
/// (menu items, keyboard shortcuts) that do work users might
/// not realize is happening — image composition, network calls,
/// clipboard writes — surface their state here so the user
/// sees feedback instead of an apparently-hung UI.
///
/// One toast at a time. `show` replaces whatever's currently
/// visible. Success / error toasts auto-dismiss after a short
/// delay; "working" toasts stay until explicitly cleared by the
/// next `show` call.
///
/// Rendering lives in `ToastOverlay`, which the app root view
/// installs as an overlay over the main content.
@Observable
@MainActor
final class ToastCenter {
    static let shared = ToastCenter()

    enum Kind {
        case working
        case success
        case error
    }

    struct Toast: Identifiable, Equatable {
        let id: UUID
        var text: String
        var kind: Kind
    }

    var current: Toast?

    private var dismissTask: Task<Void, Never>?

    func show(_ text: String, kind: Kind = .success) {
        // Replace whatever's there. Cancel any pending dismiss so
        // the new toast gets a full lifetime.
        dismissTask?.cancel()
        let toast = Toast(id: UUID(), text: text, kind: kind)
        current = toast

        // Working toasts persist until replaced. Success / error
        // toasts auto-dismiss so a one-shot operation doesn't
        // leave the HUD pinned forever.
        if kind != .working {
            let delay = kind == .error ? 4_000_000_000 : 2_000_000_000 // 4s for errors, 2s otherwise
            dismissTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay))
                guard !Task.isCancelled else { return }
                guard let self else { return }
                if self.current?.id == toast.id {
                    self.current = nil
                }
            }
        }
    }

    /// Dismiss whatever's showing right now. Used when the user
    /// clicks through a "working" toast or the operation completes
    /// without a follow-up message.
    func dismiss() {
        dismissTask?.cancel()
        current = nil
    }
}
