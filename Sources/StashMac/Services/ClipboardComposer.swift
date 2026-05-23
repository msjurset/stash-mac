import AppKit
import UniformTypeIdentifiers

/// Builds clipboard payloads from a stash item. The headline use
/// case is "I just identified a mushroom and want to send the
/// photo + the AI-generated notes to my partner over Signal" —
/// chat apps accept one clipboard representation per paste, so
/// the only way to ship image + caption in a single paste is to
/// composite them into one PNG.
///
/// This service handles the compositing (single-image + caption,
/// multi-image collage + caption) and writes the result to the
/// system pasteboard. Bare image / text / URL helpers live here
/// too so the share menu has a single entry point per option.
///
/// Renders fit comfortably into chat-app preview boxes: target
/// width 1200px, caption font auto-shrinks if the text doesn't
/// fit at the default size.
enum ClipboardComposer {

    // MARK: - Public entry points

    /// Composite image + caption (title bolded above the notes) as
    /// a single PNG on the clipboard. For multi-file items use
    /// `copyCollageWithCaption` instead. No-op when the item has
    /// no readable primary blob.
    @discardableResult
    static func copyImageWithCaption(item: StashItem) -> Bool {
        guard let image = primaryImage(for: item) else { return false }
        let composited = compose(images: [image], caption: caption(for: item))
        return writeImage(composited)
    }

    /// Lay out every attached file (primary + extras) as a grid,
    /// caption underneath, one PNG → clipboard. Falls back to a
    /// single-image render if only one image is available.
    @discardableResult
    static func copyCollageWithCaption(item: StashItem) -> Bool {
        let images = allImages(for: item)
        guard !images.isEmpty else { return false }
        let composited = compose(images: images, caption: caption(for: item))
        return writeImage(composited)
    }

    /// Bare image — no caption, no band. For when the user
    /// explicitly wants just the photo on the clipboard.
    @discardableResult
    static func copyImageOnly(item: StashItem) -> Bool {
        guard let image = primaryImage(for: item) else { return false }
        return writeImage(image)
    }

    /// Bare title + notes text. Useful when the recipient is a
    /// text-only context (terminal, code review, etc.).
    @discardableResult
    static func copyCaptionOnly(item: StashItem) -> Bool {
        let text = caption(for: item)
        guard !text.isEmpty else { return false }
        return writeText(text)
    }

    /// URL only. For link items.
    @discardableResult
    static func copyLinkOnly(item: StashItem) -> Bool {
        guard let raw = item.url, !raw.isEmpty else { return false }
        return writeText(raw)
    }

    /// "Title — URL" pair, useful for pasting a link into a chat
    /// or email with a human-readable label.
    @discardableResult
    static func copyLinkWithTitle(item: StashItem) -> Bool {
        guard let raw = item.url, !raw.isEmpty else { return false }
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let joined = title.isEmpty ? raw : "\(title)\n\(raw)"
        return writeText(joined)
    }

    /// Snippet / email body — the item's extracted text.
    @discardableResult
    static func copyTextBody(item: StashItem) -> Bool {
        let body = (item.extractedText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return false }
        return writeText(body)
    }

    /// Title + extracted text (for snippets that want a heading).
    @discardableResult
    static func copyTextWithTitle(item: StashItem) -> Bool {
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = (item.extractedText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let combined: String
        switch (title.isEmpty, body.isEmpty) {
        case (true, true):   return false
        case (false, true):  combined = title
        case (true, false):  combined = body
        case (false, false): combined = "\(title)\n\n\(body)"
        }
        return writeText(combined)
    }

    // MARK: - Internals

    private static func primaryImage(for item: StashItem) -> NSImage? {
        guard let storePath = item.storePath,
              let url = FilePathResolver.resolve(storePath: storePath),
              FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return NSImage(contentsOf: url)
    }

    private static func allImages(for item: StashItem) -> [NSImage] {
        var images: [NSImage] = []
        if let primary = primaryImage(for: item) {
            images.append(primary)
        }
        for f in item.files ?? [] {
            if let url = FilePathResolver.resolve(storePath: f.storePath),
               FileManager.default.fileExists(atPath: url.path),
               let img = NSImage(contentsOf: url) {
                images.append(img)
            }
        }
        return images
    }

    /// Build the title-then-notes caption used on composited
    /// images. Title is the first line, notes underneath. Empty
    /// when both fields are blank — caller skips the band.
    private static func caption(for item: StashItem) -> String {
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = (item.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch (title.isEmpty, notes.isEmpty) {
        case (true, true):   return ""
        case (false, true):  return title
        case (true, false):  return notes
        case (false, false): return "\(title)\n\(notes)"
        }
    }

    // MARK: - Compositing

    private static let renderTargetWidth: CGFloat = 1200
    private static let captionPadding: CGFloat = 10

    /// Compose one or more images into a single PNG with an
    /// optional caption band underneath. Layout:
    ///
    ///   single image     → image at 1200px wide, scaled at its
    ///                       native aspect ratio (no letterboxing).
    ///   2–N images       → grid (1×2, 1×3, 2×2, 2×3, 3×3…) with
    ///                       each cell aspect-fill cropped so the
    ///                       grid has no black bars between cells.
    ///
    /// Caption band sits tight under the image with minimal
    /// vertical padding — no "framing" around the photo. Font
    /// auto-shrinks if the text doesn't fit; minimum 11pt before
    /// we accept truncation. No "expand" affordance — pasted
    /// image, not an interactive view.
    private static func compose(images: [NSImage], caption: String) -> NSImage {
        let layout = pickGridLayout(count: images.count)
        let cellSize = computeCellSize(layout: layout, singleImage: images.first, count: images.count)
        let gridWidth = cellSize.width * CGFloat(layout.cols) + cellGutter * CGFloat(layout.cols - 1)
        let gridHeight = cellSize.height * CGFloat(layout.rows) + cellGutter * CGFloat(layout.rows - 1)

        let trimmedCaption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        let captionHeight = trimmedCaption.isEmpty ? 0 : measureCaptionHeight(text: trimmedCaption, width: gridWidth)

        let totalSize = NSSize(
            width: gridWidth,
            height: gridHeight + (captionHeight > 0 ? captionPadding + captionHeight + captionPadding : 0)
        )

        // Draw into an explicit `NSBitmapImageRep` rather than
        // `NSImage.lockFocus()` — lockFocus produces a screen-
        // resolution-cached representation that doesn't always
        // serialize back to PNG/TIFF cleanly (this is what was
        // making "Image with caption" appear to churn without
        // producing a clipboard payload). The explicit bitmap rep
        // gives a deterministic, exact-pixel offscreen surface.
        let widthPx = Int(ceil(totalSize.width))
        let heightPx = Int(ceil(totalSize.height))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: widthPx,
            pixelsHigh: heightPx,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return NSImage(size: totalSize)
        }
        rep.size = totalSize

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

        // Lay each image into its grid cell. AppKit coord system:
        // origin at bottom-left. We draw row-major top-down, so
        // row 0 ends up at the TOP of the canvas. Single-image
        // case sizes the cell to the image's native aspect (no
        // letterbox); multi-image collage uses aspect-fill
        // cropping so cells fully tile without black bars.
        let imageBlockOriginY = totalSize.height - gridHeight
        for (idx, img) in images.enumerated() {
            let r = idx / layout.cols
            let c = idx % layout.cols
            let cellX = CGFloat(c) * (cellSize.width + cellGutter)
            let cellY = imageBlockOriginY + CGFloat(layout.rows - 1 - r) * (cellSize.height + cellGutter)
            let cellRect = NSRect(x: cellX, y: cellY, width: cellSize.width, height: cellSize.height)
            if images.count == 1 {
                // Cell is sized to image aspect; just fill it.
                img.draw(in: cellRect, from: .zero, operation: .sourceOver, fraction: 1.0)
            } else {
                drawAspectFill(image: img, in: cellRect)
            }
        }

        // Caption band, if present.
        if captionHeight > 0 {
            let bandRect = NSRect(x: 0, y: 0, width: gridWidth, height: captionPadding + captionHeight + captionPadding)
            NSColor(white: 0.08, alpha: 1.0).setFill()
            NSBezierPath(rect: bandRect).fill()
            drawCaption(
                text: trimmedCaption,
                in: NSRect(x: captionPadding, y: captionPadding,
                           width: gridWidth - captionPadding * 2,
                           height: captionHeight)
            )
        }

        let result = NSImage(size: totalSize)
        result.addRepresentation(rep)
        return result
    }

    private static let cellGutter: CGFloat = 6

    /// Cell sizing — different rule for single vs. collage.
    /// Single image gets a cell that matches its native aspect
    /// ratio at the target width, so the rendered PNG has zero
    /// black framing. Collages keep uniform square cells so a
    /// mix of portrait / landscape sources tiles predictably;
    /// images aspect-fill inside, sacrificing edge content for
    /// a clean grid.
    private static func computeCellSize(layout: GridLayout, singleImage: NSImage?, count: Int) -> NSSize {
        let cols = CGFloat(layout.cols)
        let cellW = (renderTargetWidth - cellGutter * (cols - 1)) / cols
        if count == 1, let img = singleImage, img.size.width > 0, img.size.height > 0 {
            let aspect = img.size.height / img.size.width
            return NSSize(width: cellW, height: cellW * aspect)
        }
        return NSSize(width: cellW, height: cellW)
    }

    /// Layout grid picker — chosen so single shots are tall, pairs
    /// stack side-by-side, triplets land 1×3, four+ shifts to 2×2
    /// / 2×3 / 3×3.
    private struct GridLayout { let cols: Int; let rows: Int }
    private static func pickGridLayout(count: Int) -> GridLayout {
        switch count {
        case 1:     return GridLayout(cols: 1, rows: 1)
        case 2:     return GridLayout(cols: 2, rows: 1)
        case 3:     return GridLayout(cols: 3, rows: 1)
        case 4:     return GridLayout(cols: 2, rows: 2)
        case 5, 6:  return GridLayout(cols: 3, rows: 2)
        case 7, 8, 9: return GridLayout(cols: 3, rows: 3)
        default:
            // Past 9, square root + ceil scales generically. Rare
            // path; multi-file items don't usually go this deep.
            let side = Int(ceil(Double(count).squareRoot()))
            return GridLayout(cols: side, rows: side)
        }
    }

    private static func drawAspectFit(image: NSImage, in rect: NSRect) {
        let imgSize = image.size
        guard imgSize.width > 0, imgSize.height > 0 else { return }
        let scale = min(rect.width / imgSize.width, rect.height / imgSize.height)
        let drawW = imgSize.width * scale
        let drawH = imgSize.height * scale
        let dx = rect.origin.x + (rect.width - drawW) / 2
        let dy = rect.origin.y + (rect.height - drawH) / 2
        image.draw(in: NSRect(x: dx, y: dy, width: drawW, height: drawH),
                   from: .zero, operation: .sourceOver, fraction: 1.0)
    }

    /// Aspect-fill — image covers the entire cell, cropping
    /// the overflow on the axis with extra pixels. Used by the
    /// collage path so a 16:9 photo and a 4:3 photo can sit
    /// next to each other in square cells without one of them
    /// showing letterbox bars. Center-cropped: equal trim on
    /// both sides of the overflowing axis.
    private static func drawAspectFill(image: NSImage, in rect: NSRect) {
        let imgSize = image.size
        guard imgSize.width > 0, imgSize.height > 0 else { return }
        let scale = max(rect.width / imgSize.width, rect.height / imgSize.height)
        let drawW = imgSize.width * scale
        let drawH = imgSize.height * scale
        let dx = rect.origin.x + (rect.width - drawW) / 2
        let dy = rect.origin.y + (rect.height - drawH) / 2
        // Clip to the cell so the overflow doesn't bleed into
        // neighbouring cells.
        NSGraphicsContext.current?.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        image.draw(in: NSRect(x: dx, y: dy, width: drawW, height: drawH),
                   from: .zero, operation: .sourceOver, fraction: 1.0)
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    // MARK: - Caption typesetting

    /// Default title / notes fonts. Caption auto-shrinks (uniform
    /// across both) if text won't fit at this size; min 11pt
    /// before truncation kicks in.
    private static let titleFontSize: CGFloat = 22
    private static let notesFontSize: CGFloat = 16
    private static let minFontScale: CGFloat = 11.0 / 16.0

    /// Measure the rendered height of a caption inside `width`,
    /// auto-shrinking the font as needed to fit a reasonable
    /// number of lines. Returns 0 when text is empty.
    private static func measureCaptionHeight(text: String, width: CGFloat) -> CGFloat {
        let (titleLine, body) = splitTitleAndBody(text)
        let (titleFont, bodyFont) = fontsForFit(titleLine: titleLine, body: body, width: width)
        var h: CGFloat = 0
        if let titleLine = titleLine, !titleLine.isEmpty {
            h += measureLine(text: titleLine, font: titleFont, width: width)
            if !body.isEmpty { h += 6 } // title-to-body gap
        }
        if !body.isEmpty {
            h += measureLine(text: body, font: bodyFont, width: width)
        }
        return h
    }

    private static func drawCaption(text: String, in rect: NSRect) {
        let (titleLine, body) = splitTitleAndBody(text)
        let (titleFont, bodyFont) = fontsForFit(titleLine: titleLine, body: body, width: rect.width)

        var cursorY = rect.maxY
        if let titleLine = titleLine, !titleLine.isEmpty {
            let attr: [NSAttributedString.Key: Any] = [
                .font: titleFont,
                .foregroundColor: NSColor.white,
            ]
            let line = NSAttributedString(string: titleLine, attributes: attr)
            let h = measureLine(text: titleLine, font: titleFont, width: rect.width)
            let frame = NSRect(x: rect.minX, y: cursorY - h, width: rect.width, height: h)
            line.draw(with: frame, options: [.usesLineFragmentOrigin])
            cursorY -= (h + 6)
        }
        if !body.isEmpty {
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = .byWordWrapping
            let attr: [NSAttributedString.Key: Any] = [
                .font: bodyFont,
                .foregroundColor: NSColor(white: 0.92, alpha: 1.0),
                .paragraphStyle: para,
            ]
            let line = NSAttributedString(string: body, attributes: attr)
            let h = measureLine(text: body, font: bodyFont, width: rect.width)
            let frame = NSRect(x: rect.minX, y: cursorY - h, width: rect.width, height: h)
            line.draw(with: frame, options: [.usesLineFragmentOrigin])
        }
    }

    /// Pick the largest uniform-scale font pair such that the
    /// caption fits within ~6 body lines at default sizes. Walks
    /// down in 0.05 steps until it fits or we hit minFontScale.
    private static func fontsForFit(titleLine: String?, body: String, width: CGFloat) -> (NSFont, NSFont) {
        let maxBodyLines: CGFloat = 8
        var scale: CGFloat = 1.0
        while scale > minFontScale {
            let titleFont = NSFont.boldSystemFont(ofSize: titleFontSize * scale)
            let bodyFont = NSFont.systemFont(ofSize: notesFontSize * scale)
            let bodyHeight = body.isEmpty ? 0 : measureLine(text: body, font: bodyFont, width: width)
            let bodyLineHeight = bodyFont.boundingRectForFont.height
            if bodyHeight <= bodyLineHeight * maxBodyLines {
                return (titleFont, bodyFont)
            }
            scale -= 0.05
        }
        // Floor — accept truncation by letting the text overflow.
        return (
            NSFont.boldSystemFont(ofSize: titleFontSize * minFontScale),
            NSFont.systemFont(ofSize: notesFontSize * minFontScale)
        )
    }

    private static func splitTitleAndBody(_ caption: String) -> (String?, String) {
        // Title is the first line; body is everything after.
        if let newlineIdx = caption.firstIndex(of: "\n") {
            let title = String(caption[..<newlineIdx])
            let rest = caption[caption.index(after: newlineIdx)...]
            return (title, String(rest).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return (caption, "")
    }

    private static func measureLine(text: String, font: NSFont, width: CGFloat) -> CGFloat {
        // **MUST match the options passed to NSAttributedString.draw**
        // — different option sets produce different layouts, and an
        // asymmetric pair under-reports height by one font's leading,
        // which clips the descender of the last line in the rendered
        // band. We use `.usesLineFragmentOrigin` for both measure and
        // draw, and tack on a small safety pad for the descender that
        // boundingRect doesn't always include even at parity.
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        let attr: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: para,
        ]
        let attributed = NSAttributedString(string: text, attributes: attr)
        let bounding = attributed.boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin]
        )
        return ceil(bounding.height) + 4
    }

    // MARK: - Pasteboard writes

    private static func writeImage(_ image: NSImage) -> Bool {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return false }
        let pb = NSPasteboard.general
        pb.clearContents()
        // PNG primary; NSImage fallback for apps that prefer it.
        pb.setData(png, forType: .png)
        pb.writeObjects([image])
        return true
    }

    private static func writeText(_ text: String) -> Bool {
        let pb = NSPasteboard.general
        pb.clearContents()
        return pb.setString(text, forType: .string)
    }
}
