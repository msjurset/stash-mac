import SwiftUI
import AppKit

/// Full-window image viewer presented as a borderless NSPanel rather
/// than a SwiftUI sheet. The panel auto-closes when it loses key focus,
/// so clicking anywhere outside the viewer (including back into the
/// main app window) dismisses it. SwiftUI `.sheet` is modal on macOS
/// and blocks outside clicks, which is why we punch through to AppKit
/// for this surface.
///
/// Behaviors inside the panel:
///   - Single click → dismiss (delayed so it doesn't pre-empt a double)
///   - Double-click → toggle 1× ↔ 2.5× zoom anchored on click position
///   - Drag while zoomed → pan
///   - Pinch → magnify between 0.5× and 8×; snaps back to 1× on release
///   - Esc → dismiss
@MainActor
enum ImagePreviewPresenter {
    /// Strong reference to the live preview window. Without this the
    /// hosting controller's window deallocates as soon as the call
    /// returns since SwiftUI doesn't retain it.
    private static var current: KeyableBorderlessPanel?
    private static var resignObserver: NSObjectProtocol?

    static func present(urls: [URL], initialIndex: Int = 0) {
        // If something's already open, dismiss it first so we don't
        // stack windows on rapid double-clicks.
        dismiss()

        let view = ImagePreviewView(urls: urls, initialIndex: initialIndex, onDismiss: dismiss)
        let host = NSHostingController(rootView: view)
        let panel = KeyableBorderlessPanel(contentViewController: host)
        panel.styleMask = [.borderless, .resizable]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = false
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.cornerRadius = 12
        panel.contentView?.layer?.masksToBounds = true

        // Auto-dismiss when the user clicks outside the panel: macOS
        // sends `didResignKey` to the panel as soon as another window
        // becomes key, including the main Stash window. That's our
        // signal to close.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                ImagePreviewPresenter.dismiss()
            }
        }

        // Wire Escape → dismiss via the AppKit responder chain.
        // SwiftUI's `.onExitCommand` only fires when a SwiftUI view is
        // first responder, and this panel has no focusable element, so
        // we catch cancelOperation at the panel level instead.
        panel.onCancel = { Self.dismiss() }
        panel.onArrowKey = { delta in
            NotificationCenter.default.post(name: .imagePreviewArrowKey, object: nil, userInfo: ["delta": delta])
        }

        current = panel
        panel.center()
        panel.makeKeyAndOrderFront(nil)

        // Ensure the panel is actually key and its content is focused
        // so arrow keys work immediately without a click.
        DispatchQueue.main.async {
            panel.makeKey()
            if let contentView = panel.contentView {
                panel.makeFirstResponder(contentView)
            }
        }
    }

    static func dismiss() {
        if let token = resignObserver {
            NotificationCenter.default.removeObserver(token)
            resignObserver = nil
        }
        current?.orderOut(nil)
        current = nil
        NotificationCenter.default.post(name: .imagePreviewDismissed, object: nil)
    }
}

/// Borderless NSPanel that's allowed to become the key window. Without
/// the `canBecomeKey` override, a `.borderless` panel can't take focus,
/// which means Esc handling doesn't work and — critically — it never
/// receives the `didResignKey` notification we use to auto-dismiss on
/// outside-click.
final class KeyableBorderlessPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Set by the presenter to route the user's Escape key (sent up the
    /// responder chain as `cancelOperation`) to whatever dismissal path
    /// the embedded view uses. SwiftUI's `.onExitCommand` would do this
    /// for us if the hosted view had any focusable subview, but a pure
    /// image viewer has none — so we hook in one level lower.
    var onCancel: (() -> Void)?
    var onArrowKey: ((Int) -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: // Left
            onArrowKey?(-1)
        case 124: // Right
            onArrowKey?(1)
        default:
            super.keyDown(with: event)
        }
    }
}

extension Notification.Name {
    static let imagePreviewArrowKey = Notification.Name("stash.imagePreviewArrowKey")
    static let imagePreviewDismissed = Notification.Name("stash.imagePreviewDismissed")
}

/// Full-window image viewer rendered inside `ImagePreviewPresenter`'s
/// floating NSPanel. Click disambiguation runs after a short delay so
/// the single-click "dismiss" doesn't pre-empt a double-click "zoom".
struct ImagePreviewView: View {
    let urls: [URL]
    let initialIndex: Int
    let onDismiss: () -> Void

    @State private var currentIndex: Int = 0
    @State private var image: NSImage?
    @State private var isLoading = false

    @State private var zoom: CGFloat = 1.0
    /// Zoom level captured at the start of the in-progress pinch
    /// gesture, or nil when no pinch is happening.
    /// MagnifyGesture.magnification is gesture-relative (always
    /// begins at 1.0), so consecutive pinches multiply against this
    /// base instead of replacing zoom outright — matches the way
    /// pan's committedPan + liveDrag pair compounds drags.
    @State private var pinchBaseZoom: CGFloat? = nil
    /// Pan at gesture start; needed for the zoom-toward-cursor math
    /// so the anchor formula reads from a stable starting offset
    /// throughout the gesture instead of stair-stepping off the
    /// just-updated value.
    @State private var pinchBasePan: CGSize? = nil
    /// Center-relative cursor position captured at gesture start.
    /// "Zoom toward cursor" keeps the image-point under this anchor
    /// pinned to the same screen position as zoom changes, so the
    /// viewer center smoothly tracks the focus point — standard
    /// touch-image navigation behaviour.
    @State private var pinchAnchor: CGPoint? = nil
    @State private var committedPan: CGSize = .zero
    @State private var liveDrag: CGSize = .zero

    @State private var pendingDismiss: Task<Void, Never>?
    @State private var lastTapAt: Date = .distantPast

    private let dragThreshold: CGFloat = 4
    private let doubleClickWindow: TimeInterval = 0.28
    private let zoomedScale: CGFloat = 2.5

    var body: some View {
        let target = sheetSize()
        return GeometryReader { geo in
            // Backdrop owns the gestures so that clicking the dark
            // letterbox area around the image dismisses too. The Image
            // itself sits on top with hit-testing off — gestures fall
            // through to the backdrop regardless of where in the sheet
            // the user clicks.
            ZStack {
                Color.black
                    .contentShape(Rectangle())
                    .gesture(magnification(in: geo.size))
                    .simultaneousGesture(panOrTapGesture(in: geo.size))

                Group {
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .scaleEffect(zoom)
                            .offset(x: committedPan.width + liveDrag.width,
                                    y: committedPan.height + liveDrag.height)
                    } else if isLoading {
                        ProgressView()
                            .colorInvert()
                            .brightness(1)
                    }
                }
                .allowsHitTesting(false)

                // Navigation overlays
                if urls.count > 1 && zoom <= 1.0 {
                    HStack {
                        navButton(systemImage: "chevron.left") {
                            advance(by: -1)
                        }
                        .disabled(currentIndex == 0)
                        .opacity(currentIndex == 0 ? 0.3 : 1)

                        Spacer()

                        navButton(systemImage: "chevron.right") {
                            advance(by: 1)
                        }
                        .disabled(currentIndex == urls.count - 1)
                        .opacity(currentIndex == urls.count - 1 ? 0.3 : 1)
                    }
                    .padding(.horizontal, 20)
                }

                // Index indicator
                if urls.count > 1 && zoom <= 1.0 {
                    VStack {
                        Spacer()
                        Text("\(currentIndex + 1) / \(urls.count)")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.4))
                            .clipShape(Capsule())
                            .foregroundStyle(.white)
                            .padding(.bottom, 10)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .onExitCommand { dismiss() }
        }
        .frame(width: target.width, height: target.height)
        .onAppear {
            currentIndex = initialIndex
            load()
        }
        .onChange(of: currentIndex) { _, _ in load() }
        .focusable()
        .onExitCommand { dismiss() }
        .onReceive(NotificationCenter.default.publisher(for: .imagePreviewArrowKey)) { note in
            if let delta = note.userInfo?["delta"] as? Int {
                advance(by: delta)
            }
        }
    }

    private func navButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 24, weight: .bold))
                .padding(12)
                .background(.black.opacity(0.3))
                .clipShape(Circle())
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    private func advance(by delta: Int) {
        let next = currentIndex + delta
        guard next >= 0, next < urls.count else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            currentIndex = next
            zoom = 1.0
            committedPan = .zero
        }
    }

    private func load() {
        guard currentIndex < urls.count else { return }
        let url = urls[currentIndex]
        isLoading = true
        Task.detached(priority: .userInitiated) {
            let img = ThumbnailCache.loadOriented(from: url)
            await MainActor.run {
                self.image = img
                self.isLoading = false
            }
        }
    }

    /// Sheets on macOS ignore `idealWidth`/`idealHeight` and only honor
    /// `minWidth`/`minHeight` — so we explicitly size the sheet to take
    /// up most of the visible screen, capped to the image's natural
    /// pixel size so a tiny icon doesn't get blown up to wall-size.
    private func sheetSize() -> CGSize {
        let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1400, height: 900)
        let maxByScreen = CGSize(width: screen.width * 0.9, height: screen.height * 0.9)
        let imageSize = image?.size ?? CGSize(width: 800, height: 600)
        guard imageSize.width > 0, imageSize.height > 0 else { return maxByScreen }
        // Floor to a usable minimum so very small images still get a
        // generous viewer pane.
        let minWidth: CGFloat = 700
        let minHeight: CGFloat = 500
        let width = max(min(imageSize.width, maxByScreen.width), minWidth)
        let height = max(min(imageSize.height, maxByScreen.height), minHeight)
        return CGSize(width: width, height: height)
    }

    // MARK: - Gestures

    private func magnification(in canvas: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { val in
                // First sample of a new gesture (pinchBaseZoom is
                // nil) — snapshot the current zoom, pan, and the
                // center-relative cursor position so the gesture
                // can read from a stable origin throughout. Without
                // these snapshots:
                //   - zoom would reset to the gesture's local
                //     1.0..magnification factor and lose prior scale
                //   - the pan formula would chase its own tail by
                //     reading the just-written committedPan
                //   - the anchor would drift if MagnifyGesture
                //     reported any noise in startLocation
                if pinchBaseZoom == nil {
                    pinchBaseZoom = zoom
                    pinchBasePan = committedPan
                    pinchAnchor = CGPoint(
                        x: val.startLocation.x - canvas.width / 2,
                        y: val.startLocation.y - canvas.height / 2
                    )
                }
                let z0 = pinchBaseZoom ?? zoom
                let basePan = pinchBasePan ?? committedPan
                let anchor = pinchAnchor ?? .zero
                let newZoom = clamp(z0 * val.magnification, lower: 0.5, upper: 8.0)
                zoom = newZoom
                // Zoom-toward-cursor: keep the image-point under the
                // gesture-start cursor at the same screen position
                // for the entire pinch. As zoom grows, the visible
                // crop tightens around that anchor — the viewer
                // "center" appears to follow the mouse smoothly.
                //
                // Derivation: at gesture start the image-point I at
                // cursor satisfies anchor = I*z0 + basePan. We want
                // anchor = I*newZoom + p' to hold throughout, so
                //   p' = anchor*(1 - newZoom/z0) + basePan*(newZoom/z0)
                let ratio = newZoom / z0
                committedPan = CGSize(
                    width: anchor.x * (1 - ratio) + basePan.width * ratio,
                    height: anchor.y * (1 - ratio) + basePan.height * ratio
                )
            }
            .onEnded { _ in
                pinchBaseZoom = nil
                pinchBasePan = nil
                pinchAnchor = nil
                if zoom < 1 {
                    withAnimation(.easeOut(duration: 0.18)) {
                        zoom = 1
                        committedPan = .zero
                    }
                }
            }
    }

    private func panOrTapGesture(in canvas: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { val in
                // Only treat as a pan once we're zoomed in AND the
                // cursor has actually moved past the tap threshold.
                let distance = hypot(val.translation.width, val.translation.height)
                if zoom > 1 && distance > dragThreshold {
                    liveDrag = val.translation
                }
            }
            .onEnded { val in
                let distance = hypot(val.translation.width, val.translation.height)
                if distance > dragThreshold {
                    // It was a drag — commit the pan, clear live offset.
                    if zoom > 1 {
                        committedPan.width += val.translation.width
                        committedPan.height += val.translation.height
                    }
                    liveDrag = .zero
                    return
                }
                liveDrag = .zero
                handleTap(at: val.startLocation, in: canvas)
            }
    }

    // MARK: - Tap disambiguation

    private func handleTap(at location: CGPoint, in canvas: CGSize) {
        let now = Date()
        if now.timeIntervalSince(lastTapAt) < doubleClickWindow {
            // Double click: zoom toggle around the click point.
            pendingDismiss?.cancel()
            pendingDismiss = nil
            lastTapAt = .distantPast
            withAnimation(.easeInOut(duration: 0.22)) {
                if zoom > 1.5 {
                    zoom = 1
                    committedPan = .zero
                } else {
                    zoom = zoomedScale
                    committedPan = panOffsetForZoom(toward: location, in: canvas, zoom: zoomedScale)
                }
            }
            return
        }

        lastTapAt = now
        pendingDismiss?.cancel()
        pendingDismiss = Task { @MainActor in
            try? await Task.sleep(for: .seconds(doubleClickWindow))
            guard !Task.isCancelled else { return }
            dismiss()
        }
    }

    /// Compute a pan offset such that the point under the cursor stays
    /// roughly in place after scaling around the canvas center. Without
    /// this, a 2.5× zoom always anchors on the image center; the user
    /// asked for the click position to stay put.
    private func panOffsetForZoom(toward point: CGPoint, in canvas: CGSize, zoom: CGFloat) -> CGSize {
        let dx = point.x - canvas.width / 2
        let dy = point.y - canvas.height / 2
        // Translation needed to keep `point` stationary after scaling
        // by `zoom` around the center: (1 - zoom) * (point - center).
        return CGSize(width: (1 - zoom) * dx, height: (1 - zoom) * dy)
    }

    private func dismiss() {
        pendingDismiss?.cancel()
        pendingDismiss = nil
        onDismiss()
    }

    private func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        min(max(value, lower), upper)
    }
}
