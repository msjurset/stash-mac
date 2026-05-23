import SwiftUI

/// Renders the current `ToastCenter` message as a small pill at
/// the top of the main window. Subscribes to the shared
/// `ToastCenter` so any background action — clipboard
/// composition, network calls, etc. — gets visible feedback
/// without the originating call site needing to know about
/// SwiftUI views.
///
/// Install once at the root of the main view hierarchy via
/// `.overlay(alignment: .top) { ToastOverlay() }`.
struct ToastOverlay: View {
    @Bindable var center: ToastCenter = .shared

    var body: some View {
        Group {
            if let toast = center.current {
                ToastPill(toast: toast)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: center.current)
        .padding(.top, 12)
        .allowsHitTesting(false)
    }
}

private struct ToastPill: View {
    let toast: ToastCenter.Toast

    var body: some View {
        HStack(spacing: 8) {
            icon
            Text(toast.text)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            Capsule()
                .fill(.thinMaterial)
                .overlay(
                    Capsule()
                        .stroke(Color.black.opacity(0.12), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        )
    }

    @ViewBuilder private var icon: some View {
        switch toast.kind {
        case .working:
            ProgressView()
                .controlSize(.small)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }
}
