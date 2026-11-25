import AppKit
import Foundation
import Testing

@testable import StashMac

@MainActor
@Suite("Editing, Focus & Toast Notifications", .serialized)
struct EditingAndToastTests {

    // MARK: - DesktopNotifier & ToastCenter

    @Test("DesktopNotifier escapes quotes, backslashes, and newlines for AppleScript")
    func desktopNotifierEscaping() {
        let quoted = DesktopNotifier.appleScriptQuote("He said \"hello\\world\"\nand\rreturned")
        #expect(quoted == "\"He said \\\"hello\\\\world\\\" and returned\"")

        let script = DesktopNotifier.buildAppleScript(title: "Stashed", message: "Clipboard \"text\" added")
        #expect(script == "display notification \"Clipboard \\\"text\\\" added\" with title \"Stashed\"")
    }

    @Test("ToastCenter updates current toast and dismisses cleanly")
    func toastCenterLifecycle() {
        let center = ToastCenter.shared
        center.dismiss()
        #expect(center.current == nil)

        center.show("Stashing from Clipboard…", kind: .working)
        #expect(center.current?.text == "Stashing from Clipboard…")
        #expect(center.current?.kind == .working)

        center.show("Stashed from Clipboard", kind: .success)
        #expect(center.current?.text == "Stashed from Clipboard")
        #expect(center.current?.kind == .success)

        center.dismiss()
        #expect(center.current == nil)
    }

    @Test("SelectionGrabber.stashClipboard emits toast and desktop notification on empty pasteboard")
    func stashClipboardEmptyPasteboardEmitsFeedback() {
        let pb = NSPasteboard.withUniqueName()
        pb.clearContents()

        ToastCenter.shared.dismiss()
        var captured: DesktopNotifier.NotificationRecord?
        DesktopNotifier.testObserver = { record in
            captured = record
        }
        defer {
            DesktopNotifier.testObserver = nil
            ToastCenter.shared.dismiss()
            pb.releaseGlobally()
        }

        let grabber = SelectionGrabber()
        grabber.stashClipboard(from: pb)

        #expect(grabber.status == "Clipboard is empty")
        #expect(ToastCenter.shared.current?.text == "Clipboard is empty")
        #expect(ToastCenter.shared.current?.kind == .error)
        #expect(captured == DesktopNotifier.NotificationRecord(
            title: "Stash",
            message: "Clipboard is empty.",
            link: nil
        ))
    }

    // MARK: - VimEditorScrollView & VimHostTextView Sizing / Focus

    @Test("VimEditorScrollView expands zero-height VimHostTextView to fill scroll content area")
    func scrollViewExpandsZeroHeightDocumentView() {
        let scrollView = VimEditorScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 140))
        let textStorage = NSTextStorage(string: "")
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(containerSize: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)

        let tv = VimHostTextView(frame: .zero, textContainer: textContainer)
        tv.textContainerInset = NSSize(width: 4, height: 6)
        scrollView.documentView = tv

        scrollView.syncDocumentViewSize()

        #expect(tv.frame.width == scrollView.contentSize.width)
        #expect(tv.frame.height >= scrollView.contentSize.height)
        #expect(tv.minSize.height == scrollView.contentSize.height)

        // Verify hit-testing inside the empty editor area resolves to VimHostTextView
        let hitView = tv.hitTest(NSPoint(x: 50, y: 50))
        #expect(hitView === tv)
    }

    // MARK: - Glyph Hit-Testing (Notes & Extracted Text Edit Mode)

    @Test("VimHostTextView.isPointOnGlyph distinguishes visible glyphs from trailing newline whitespace")
    func vimHostTextViewGlyphHitTesting() {
        let tv = makeConfiguredVimTextView(text: "Hello\nWorld", size: NSSize(width: 400, height: 120))

        // Empty text never matches a glyph
        let emptyTV = makeConfiguredVimTextView(text: "", size: NSSize(width: 400, height: 120))
        #expect(emptyTV.isPointOnGlyph(NSPoint(x: 10, y: 10)) == false)

        // Point directly on the first character 'H'
        let firstGlyphPoint = glyphCenter(in: tv, charIndex: 0)
        #expect(tv.isPointOnGlyph(firstGlyphPoint) == true)

        // Point far to the right of "Hello\n" on line 1 (maps to the '\n' character index 5,
        // whose layout bounding rect extends across the line width, but is whitespace).
        let trailingLineSpacePoint = NSPoint(x: 320, y: firstGlyphPoint.y)
        #expect(tv.isPointOnGlyph(trailingLineSpacePoint) == false)

        // Point below all rendered lines
        let belowTextPoint = NSPoint(x: firstGlyphPoint.x, y: 100)
        #expect(tv.isPointOnGlyph(belowTextPoint) == false)
    }

    @Test("ClickAwareTextView.isPointOnGlyph distinguishes visible glyphs from spaces and newlines")
    func clickAwareTextViewGlyphHitTesting() {
        let tv = makeConfiguredClickAwareTextView(text: "Alpha Beta\nGamma", size: NSSize(width: 400, height: 120))

        // Point on 'A' (index 0) -> true
        let alphaPoint = glyphCenter(in: tv, charIndex: 0)
        #expect(tv.isPointOnGlyph(alphaPoint) == true)

        // Point on space ' ' between Alpha and Beta (index 5) -> false
        let spacePoint = glyphCenter(in: tv, charIndex: 5)
        #expect(tv.isPointOnGlyph(spacePoint) == false)

        // Point in empty space to the right of line 1 -> false
        let rightBlankPoint = NSPoint(x: 350, y: alphaPoint.y)
        #expect(tv.isPointOnGlyph(rightBlankPoint) == false)
    }

    @Test("ClickAwareTextView double-click fires onDoubleClick and cancels pending single-click")
    func clickAwareTextViewDoubleClickTriggersEditPopover() async throws {
        let tv = makeConfiguredClickAwareTextView(text: "Click or double-click me", size: NSSize(width: 400, height: 100))

        var singleClickCount = 0
        var doubleClickCount = 0
        tv.onSingleClick = { _ in singleClickCount += 1 }
        tv.onDoubleClick = { doubleClickCount += 1 }

        let clickPoint = glyphCenter(in: tv, charIndex: 2)

        // Simulate first click of a double-click sequence
        if let down1 = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: clickPoint,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1.0
        ) {
            tv.mouseDown(with: down1)
        }

        // Immediately send the second click (clickCount: 2)
        if let down2 = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: clickPoint,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime + 0.05,
            windowNumber: 0,
            context: nil,
            eventNumber: 2,
            clickCount: 2,
            pressure: 1.0
        ) {
            tv.mouseDown(with: down2)
        }

        #expect(doubleClickCount == 1)

        // Wait past the 0.25s single-click debounce to confirm single-click was cancelled
        try await Task.sleep(nanoseconds: 350_000_000)
        #expect(singleClickCount == 0)
    }

    @Test("ClickAwareTextView single-click fires onSingleClick with character index")
    func clickAwareTextViewSingleClickFiresWithCharIndex() async throws {
        let tv = makeConfiguredClickAwareTextView(text: "Click to edit inline", size: NSSize(width: 400, height: 100))

        var receivedIndex: Int?
        var singleClickCount = 0
        tv.onSingleClick = { idx in
            singleClickCount += 1
            receivedIndex = idx
        }

        let clickPoint = glyphCenter(in: tv, charIndex: 6)
        let eventLocation = tv.convert(clickPoint, to: nil)
        if let down1 = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: eventLocation,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1.0
        ) {
            tv.mouseDown(with: down1)
        }

        try await Task.sleep(nanoseconds: 350_000_000)
        #expect(singleClickCount == 1)
        #expect(receivedIndex == 6)
    }

    @Test("VimHostTextView double-click on whitespace triggers onDoubleClickWhitespace")
    func vimHostTextViewDoubleClickOnWhitespaceOpensPopover() {
        let tv = makeConfiguredVimTextView(text: "Short line\nSecond line", size: NSSize(width: 400, height: 120))

        var whitespaceDoubleClicked = false
        tv.onDoubleClickWhitespace = {
            whitespaceDoubleClicked = true
        }

        let firstGlyph = glyphCenter(in: tv, charIndex: 0)
        // Click in the blank space far to the right of "Short line\n"
        let blankPoint = NSPoint(x: 340, y: firstGlyph.y)
        let eventLocation = tv.convert(blankPoint, to: nil)

        if let down2 = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: eventLocation,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 2,
            pressure: 1.0
        ) {
            tv.mouseDown(with: down2)
        }

        #expect(whitespaceDoubleClicked == true)
    }

    @Test("GlobalSearchPanel stays on top layer and becomes key above main window")
    func globalSearchPanelAboveMainWindow() async throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)

        let mainWin = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1000, height: 700),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        mainWin.title = "MainStashWindow"
        installFieldEditorInterceptor(on: mainWin)
        let mainField = NoAutoFillTextField(frame: NSRect(x: 20, y: 20, width: 200, height: 28))
        mainWin.contentView?.addSubview(mainField)
        mainWin.makeKeyAndOrderFront(nil)
        _ = mainWin.makeFirstResponder(mainField)
        try await Task.sleep(nanoseconds: 50_000_000)

        let store = StashStore()
        let aiPrefs = AIPrefsStore()
        let helpModel = HelpOverlayModel()
        GlobalSearchController.shared.configure(store: store, aiPrefs: aiPrefs, helpModel: helpModel)
        GlobalSearchController.shared.show()

        let panels = app.windows.compactMap { $0 as? GlobalSearchPanel }
        let panel = try #require(panels.first)

        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(panel.isVisible == true)
        #expect(panel.canBecomeKey == true)
        #expect(panel.canBecomeMain == false)
        #expect(panel.hidesOnDeactivate == false)
        #expect(!panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.level == .modalPanel)
        #expect(panel.level.rawValue > mainWin.level.rawValue)

        let nums = NSWindow.windowNumbers(options: [.allApplications])?.map(\.intValue) ?? []
        if let panelIdx = nums.firstIndex(of: panel.windowNumber),
           let mainIdx = nums.firstIndex(of: mainWin.windowNumber) {
            #expect(panelIdx < mainIdx, "GlobalSearchPanel must be ordered in front of the main window")
        }

        mainWin.orderOut(nil)
        GlobalSearchController.shared.hide()
        #expect(panel.isVisible == false)
    }

    // MARK: - Helpers

    private func makeConfiguredVimTextView(text: String, size: NSSize) -> VimHostTextView {
        let textStorage = NSTextStorage(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 13)
        ])
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(containerSize: NSSize(width: size.width, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)

        let tv = VimHostTextView(frame: NSRect(origin: .zero, size: size), textContainer: textContainer)
        tv.font = .systemFont(ofSize: 13)
        tv.textContainerInset = NSSize(width: 4, height: 6)
        layoutManager.ensureLayout(for: textContainer)
        return tv
    }

    private func makeConfiguredClickAwareTextView(text: String, size: NSSize) -> ClickAwareTextView {
        let attr = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 13)
        ])
        let textStorage = NSTextStorage(attributedString: attr)
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(containerSize: NSSize(width: size.width, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)

        let tv = ClickAwareTextView(frame: NSRect(origin: .zero, size: size), textContainer: textContainer)
        tv.attributedText = attr
        layoutManager.ensureLayout(for: textContainer)
        return tv
    }

    private func glyphCenter(in tv: NSTextView, charIndex: Int) -> NSPoint {
        let layoutManager = tv.layoutManager!
        let textContainer = tv.textContainer!
        layoutManager.ensureLayout(for: textContainer)
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: charIndex)
        let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyphIndex, length: 1), in: textContainer)
        return NSPoint(
            x: rect.midX + tv.textContainerOrigin.x,
            y: rect.midY + tv.textContainerOrigin.y
        )
    }
}
