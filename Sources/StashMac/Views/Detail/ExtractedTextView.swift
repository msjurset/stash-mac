import SwiftUI
import AppKit

struct ExtractedTextView: View {
    @Environment(StashStore.self) private var store
    let text: String
    let itemID: String

    @State private var isExpanded = false
    @State private var showEditor = false
    @State private var editedText = ""

    private var isTruncated: Bool { text.count > 500 }

    private var displayText: String {
        (isTruncated && !isExpanded) ? String(text.prefix(500)) + "..." : text
    }

    var body: some View {
        DetailSection(title: "Extracted Text") {
            VStack(alignment: .leading, spacing: 8) {
                MarkdownText(displayText, isSelectable: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    // NSEvent monitor handles both single- and double-click
                    // *before* AppKit, so selectable text doesn't swallow
                    // them for cursor-positioning or word-selection while
                    // drag-to-select still works.
                    .background(ClickCatcher(
                        onSingleClick: {
                            if isTruncated {
                                withAnimation { isExpanded.toggle() }
                            }
                        },
                        onDoubleClick: openEditor
                    ))
                    .popover(isPresented: $showEditor, arrowEdge: .top) {
                        editorPopover
                    }

                if isTruncated {
                    Button(isExpanded ? "Show Less" : "Show More") {
                        withAnimation { isExpanded.toggle() }
                    }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                }
            }
        }
    }

    private func openEditor() {
        editedText = text
        showEditor = true
    }

    /// Popout editor. Dismiss (click-off or Escape) saves any change back
    /// to the CLI via `store.editItem`. No inner chrome — the whole popover
    /// reads as a single tinted editor box.
    private var editorPopover: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Edit Extracted Text")
                    .font(.headline)
                Spacer()
                Text("Click away to save")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            TransparentTextEditor(text: $editedText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 780, height: 520)
        .background(Color(nsColor: .textBackgroundColor))
        .onDisappear {
            if editedText != text {
                store.editItem(
                    id: itemID,
                    title: nil,
                    note: nil,
                    extractedText: editedText,
                    addTags: [],
                    removeTags: [],
                    collection: nil
                )
            }
        }
    }
}

/// NSEvent-level click handler that fires `onSingleClick` and
/// `onDoubleClick` inside the view's bounds — *before* AppKit's text view
/// can claim them for cursor-positioning or word-selection. Drag gestures
/// pass through untouched so drag-to-select still works.
///
/// Logic:
/// - `mouseDown` (clickCount 1): remember the location, start tracking.
/// - `mouseDragged`: if movement exceeds the drag threshold, mark dragged.
/// - `mouseUp`: if not dragged, schedule the single-click action (deferred
///   so a follow-up double-click can cancel it).
/// - `mouseDown` (clickCount 2): cancel pending single-click, fire double,
///   and consume the event so AppKit doesn't word-select.
private struct ClickCatcher: NSViewRepresentable {
    let onSingleClick: () -> Void
    let onDoubleClick: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        CatcherView(onSingleClick: onSingleClick, onDoubleClick: onDoubleClick)
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.onSingleClick = onSingleClick
        nsView.onDoubleClick = onDoubleClick
    }

    /// Without this, NSViewRepresentable defaults to intrinsicContentSize
    /// (zero for a bare NSView) — `bounds` stays at .zero, and the
    /// bounds-contains check in the event monitor always fails.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CatcherView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 10, height: 10))
    }

    final class CatcherView: NSView {
        var onSingleClick: () -> Void
        var onDoubleClick: () -> Void
        private var monitor: Any?
        private var pendingSingle: DispatchWorkItem?
        private var downLocation: NSPoint?
        private var downInside = false
        private var didDrag = false
        /// macOS default drag threshold (in points, squared).
        private static let dragThresholdSq: CGFloat = 16

        init(onSingleClick: @escaping () -> Void, onDoubleClick: @escaping () -> Void) {
            self.onSingleClick = onSingleClick
            self.onDoubleClick = onDoubleClick
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
                return
            }
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
            ) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                return self.process(event)
            }
        }

        private func process(_ event: NSEvent) -> NSEvent? {
            let pointInView = convert(event.locationInWindow, from: nil)
            let inBounds = bounds.contains(pointInView)

            switch event.type {
            case .leftMouseDown:
                if event.clickCount == 2 && downInside && inBounds {
                    // Second click of a double-click — cancel the pending
                    // single-click work and fire double instead.
                    pendingSingle?.cancel()
                    pendingSingle = nil
                    downInside = false
                    didDrag = false
                    DispatchQueue.main.async { self.onDoubleClick() }
                    return nil
                }
                if event.clickCount == 1 && inBounds {
                    downInside = true
                    didDrag = false
                    downLocation = event.locationInWindow
                    // Schedule on mouseDown (not mouseUp) — NSTextView's
                    // nested tracking loop swallows mouseUp *and*
                    // mouseDragged before our monitor sees them, so we
                    // can't rely on drag events. Instead, check the live
                    // cursor position at fire time: if it moved past the
                    // drag threshold, the user was drag-selecting — skip.
                    let work = DispatchWorkItem { [weak self] in
                        guard let self, let window = self.window, let down = self.downLocation else { return }
                        let current = window.mouseLocationOutsideOfEventStream
                        let dx = current.x - down.x
                        let dy = current.y - down.y
                        if dx * dx + dy * dy > Self.dragThresholdSq {
                            return
                        }
                        self.onSingleClick()
                    }
                    pendingSingle?.cancel()
                    pendingSingle = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
                } else {
                    downInside = false
                }
                return event

            case .leftMouseDragged:
                if downInside, let down = downLocation {
                    let dx = event.locationInWindow.x - down.x
                    let dy = event.locationInWindow.y - down.y
                    if dx * dx + dy * dy > Self.dragThresholdSq {
                        didDrag = true
                        // Kill the pending single-click the moment a drag
                        // is detected — otherwise it fires mid-selection
                        // and the collapsed text pulls content out from
                        // under the user's drag.
                        pendingSingle?.cancel()
                        pendingSingle = nil
                    }
                }
                return event

            case .leftMouseUp:
                // Not load-bearing — NSTextView's tracking loop often
                // swallows this before it reaches us. Reset state if we do
                // see it, but don't rely on it.
                return event

            default:
                return event
            }
        }
    }
}

/// NSTextView-backed editor with a transparent background so the popover's
/// tinted background shows through. SwiftUI's `TextEditor` + popover +
/// `scrollContentBackground(.hidden)` combo has intermittent rendering bugs
/// (empty popover body); wrapping NSTextView avoids them.
private struct TransparentTextEditor: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = .textColor
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.string = text
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TransparentTextEditor
        init(_ parent: TransparentTextEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}
