import SwiftUI

/// The colored capsule badge shown on each row of the activity feed
/// (FIRE / SKIP / RETRO / CAPTURE / ERROR). Click to open a popover
/// explaining what the type means and how it got logged.
///
/// Centralized here because both the global Activity view and the
/// per-rule Activity tab inside RuleDetailView render this same pill,
/// and we want consistent color/icon/explanation across both.
struct RuleEventTypeBadge: View {
    let type: RuleEvent.EventType
    @State private var showPopover = false

    var body: some View {
        Button {
            showPopover = true
        } label: {
            Text(type.label.uppercased())
                .font(.caption2.bold())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RuleEventTypeBadge.color(for: type).opacity(0.18), in: Capsule())
                .foregroundStyle(RuleEventTypeBadge.color(for: type))
        }
        .buttonStyle(.plain)
        .help("Click to see what this means")
        .popover(isPresented: $showPopover, arrowEdge: .top) {
            badgePopover
        }
    }

    private var badgePopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: type.icon)
                    .foregroundStyle(RuleEventTypeBadge.color(for: type))
                Text(type.label.uppercased())
                    .font(.caption.bold())
                    .foregroundStyle(RuleEventTypeBadge.color(for: type))
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(type.headline)
                    .font(.caption.weight(.semibold))
            }
            Text(type.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 320)
    }

    /// Canonical color per event type. Reused by activity rows for
    /// the icon's foreground tint so the badge and the row's leading
    /// glyph share a hue.
    static func color(for type: RuleEvent.EventType) -> Color {
        switch type {
        case .fire:    return .green
        case .skip:    return .red
        case .retro:   return .blue
        case .capture: return .teal
        case .error:   return .orange
        }
    }
}
