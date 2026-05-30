import SwiftUI

/// Where VimAwareEditor renders its in-editor badge / status
/// affordances. See VimAwareEditor for the trade-offs of each.
public enum VimBadgePlacement: Sendable {
    case topRightOverlay
    case bottomFooter
    case external
}

/// One-click vim activator for editor chrome where typing `/vim`
/// would be awkward (popover headers, sheet toolbars). Shows a
/// compact `:_` label so the affordance reads as "vim command
/// line." Hidden while vim is already active — the VimModeBadge
/// takes over that slot. Pair this with VimModeBadge in the same
/// HStack and they'll never both show at once.
struct VimActivateButton: View {
    @Bindable var controller: VimModeController

    var body: some View {
        if controller.currentMode != .vim {
            Button(action: { controller.activate() }) {
                Text(":_")
                    .font(.system(.caption, design: .monospaced).bold())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.08))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("Activate vim mode (same as typing /vim)")
        }
    }
}

/// Tiny pill shown next to a VimHostEditor while vim is active.
/// Displays `engine.badge` (VIM:N, VIM:I, :q, /term) so the user
/// can see which submode the engine is in. Click anywhere on the
/// pill to exit vim (writes the controller back to nil and clears
/// the editor's mode flag).
///
/// Includes a `?` button on the right that opens the
/// VimCheatsheetView popover — every supported command in 3
/// columns so the user can discover the engine's vocabulary.
struct VimModeBadge: View {
    @Bindable var controller: VimModeController

    var body: some View {
        if controller.currentMode == .vim {
            HStack(spacing: 6) {
                Button(action: { controller.exit() }) {
                    HStack(spacing: 3) {
                        Text(controller.badgeText)
                            .font(.caption2.bold())
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.3))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help("Vim mode — click to exit, or type :q / :vim / :wq in normal mode.")

                Button(action: { controller.showCheatsheet.toggle() }) {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help("Vim cheatsheet")
                .popover(isPresented: $controller.showCheatsheet, arrowEdge: .bottom) {
                    VimCheatsheetView()
                }
            }
        }
    }
}

/// Vim-style status line pinned to the bottom of an editor. Only
/// renders when vim is active — VimAwareEditor decides whether to
/// include it based on its badgePlacement.
///
/// Layout: thin top divider (visually separates from the text
/// body), then a one-line strip with mode/command text on the
/// left (echoes `engine.badge` so we get `VIM:N` / `VIM:I` / `:q`
/// / `/term` automatically) and a small close + cheatsheet
/// button pair on the right.
///
/// Matches vim's own bottom status line in spirit — gives the
/// user a persistent anchor for "I am in vim, here's where" while
/// staying out of the text area.
struct VimStatusFooter: View {
    @Bindable var controller: VimModeController

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                Text(controller.badgeText)
                    .font(.system(.caption, design: .monospaced).bold())
                    .foregroundStyle(.primary)
                Spacer()
                Button(action: { controller.showCheatsheet.toggle() }) {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help("Vim cheatsheet")
                .popover(isPresented: $controller.showCheatsheet, arrowEdge: .bottom) {
                    VimCheatsheetView()
                }
                Button(action: { controller.exit() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help("Exit vim mode")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.accentColor.opacity(0.1))
        }
    }
}
