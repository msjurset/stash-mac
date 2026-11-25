import AppKit
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// Renders a publication-quality, multi-page-aware Recipe Card PDF from `RecipeData`
/// and optional `StashItem` metadata (hero photo / thumbnail, source URL).
///
/// Visual design follows an editorial cookbook layout:
/// - Warm ivory paper canvas with a terracotta top accent bar
/// - Serif display title, cuisine/category pill badges, author & domain byline,
///   italic headnote description, and optional rounded hero thumbnail photo
/// - Structured metadata strip (Prep, Cook, Total, Yield, Cooked count)
/// - Two-column magazine layout on Page 1 (Ingredients checklist on the left,
///   numbered Preparation steps with terracotta badges on the right), with
///   automatic multi-page continuation when either column overflows
/// - Nutrition facts pill card and Kitchen Cook Log history card
/// - Page footer with source URL attribution and "Page X of Y" numbering
enum RecipePDFGenerator {

    // MARK: - Page Geometry (US Letter: 612 x 792 pt)

    private static let pageWidth: CGFloat = 612
    private static let pageHeight: CGFloat = 792
    private static let marginX: CGFloat = 42
    private static let topMargin: CGFloat = 42
    private static let bottomMargin: CGFloat = 52
    private static var contentWidth: CGFloat { pageWidth - marginX * 2 }
    private static var maxContentY: CGFloat { pageHeight - bottomMargin }

    // Two-column geometry for Ingredients (left) + Instructions (right)
    private static let leftColWidth: CGFloat = 176
    private static let colGutter: CGFloat = 22
    private static var rightColX: CGFloat { marginX + leftColWidth + colGutter }
    private static var rightColWidth: CGFloat { contentWidth - leftColWidth - colGutter }

    // MARK: - Editorial Color Palette

    private static let pageBgColor = NSColor(srgbRed: 0.988, green: 0.984, blue: 0.973, alpha: 1.0)      // #FCFBF8
    private static let cardBgColor = NSColor(srgbRed: 0.961, green: 0.937, blue: 0.902, alpha: 1.0)      // #F5EFE6
    private static let sidebarBgColor = NSColor(srgbRed: 0.973, green: 0.957, blue: 0.929, alpha: 1.0)   // #F8F4ED
    private static let borderColor = NSColor(srgbRed: 0.898, green: 0.871, blue: 0.816, alpha: 1.0)      // #E5DEC9
    private static let terracotta = NSColor(srgbRed: 0.831, green: 0.365, blue: 0.133, alpha: 1.0)       // #D45D22
    private static let terracottaSoft = NSColor(srgbRed: 0.976, green: 0.922, blue: 0.886, alpha: 1.0)   // #F9EBE2
    private static let inkPrimary = NSColor(srgbRed: 0.110, green: 0.098, blue: 0.090, alpha: 1.0)       // #1C1917
    private static let inkSecondary = NSColor(srgbRed: 0.341, green: 0.325, blue: 0.306, alpha: 1.0)     // #57534E
    private static let inkTertiary = NSColor(srgbRed: 0.549, green: 0.510, blue: 0.471, alpha: 1.0)      // #8C8278
    private static let starAmber = NSColor(srgbRed: 0.851, green: 0.467, blue: 0.024, alpha: 1.0)        // #D97706

    // MARK: - Public API

    /// Resolves structured `RecipeData` from `item.recipe` or falls back to
    /// deterministic plaintext extraction when the item is a recipe snippet/note.
    static func resolveRecipe(for item: StashItem) -> RecipeData? {
        if let recipe = item.recipe {
            return recipe
        }
        if let notes = item.notes, !notes.isEmpty,
           let extracted = RecipeExtractor.extractFromPlaintext(notes, fallbackTitle: item.title, sourceURL: item.url) {
            return extracted
        }
        if let text = item.extractedText, !text.isEmpty,
           let extracted = RecipeExtractor.extractFromPlaintext(text, fallbackTitle: item.title, sourceURL: item.url) {
            return extracted
        }
        return nil
    }

    /// Renders the recipe into an in-memory PDF `Data` blob.
    static func renderPDF(for recipe: RecipeData, item: StashItem? = nil) -> Data? {
        let heroImage = loadHeroImage(for: item)

        // Pass 1: dry-run layout to determine exact page count for "Page X of Y" footers.
        let totalPages = max(1, performLayout(recipe: recipe, item: item, heroImage: heroImage, context: nil, totalPages: 1))

        // Pass 2: actual vector PDF generation.
        let pdfData = NSMutableData()
        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData) else { return nil }
        var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        guard let cgContext = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }

        _ = performLayout(recipe: recipe, item: item, heroImage: heroImage, context: cgContext, totalPages: totalPages)
        cgContext.closePDF()

        return pdfData as Data
    }

    /// Writes the rendered Recipe PDF to a human-readable filename (`<recipe-title>.pdf`)
    /// inside the temporary share staging directory.
    static func stagePDFFile(for recipe: RecipeData, item: StashItem? = nil) -> URL? {
        guard let data = renderPDF(for: recipe, item: item) else { return nil }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("stash-share", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let slug = slugify(recipe.title.isEmpty ? (item?.title ?? "recipe") : recipe.title)
        let dest = dir.appendingPathComponent("\(slug).pdf")
        try? FileManager.default.removeItem(at: dest)
        do {
            try data.write(to: dest, options: .atomic)
            return dest
        } catch {
            return nil
        }
    }

    /// Copies the Recipe PDF to the system pasteboard both as a staged file URL
    /// (so pasting into Messages, Signal, Mail, Slack, or Finder attaches `<slug>.pdf`)
    /// and as raw `.pdf` data.
    @discardableResult
    static func copyPDFToClipboard(for recipe: RecipeData, item: StashItem? = nil) -> Bool {
        guard let data = renderPDF(for: recipe, item: item) else { return false }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(data, forType: .pdf)
        if let fileURL = stagePDFFile(for: recipe, item: item) {
            pb.writeObjects([fileURL as NSURL])
        }
        return true
    }

    /// Opens an `NSSavePanel` to save the Recipe PDF to disk.
    @MainActor
    static func savePDFWithPanel(for recipe: RecipeData, item: StashItem? = nil) {
        guard let data = renderPDF(for: recipe, item: item) else {
            ToastCenter.shared.show("Couldn't generate Recipe PDF", kind: .error)
            return
        }
        let panel = NSSavePanel()
        panel.title = "Save Recipe PDF"
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        let slug = slugify(recipe.title.isEmpty ? (item?.title ?? "recipe") : recipe.title)
        panel.nameFieldStringValue = "\(slug).pdf"

        if panel.runModal() == .OK, let url = panel.url {
            do {
                try data.write(to: url, options: .atomic)
                ToastCenter.shared.show("Saved \(url.lastPathComponent)", kind: .success)
            } catch {
                ToastCenter.shared.show("Failed to save PDF", kind: .error)
            }
        }
    }

    @MainActor
    private static var activeSharePicker: NSSharingServicePicker?

    /// Opens the macOS share sheet (`NSSharingServicePicker`) pre-populated with
    /// the staged `<recipe-slug>.pdf` file.
    ///
    /// IMPORTANT: Pass ONLY `[fileURL]` (never mix a `file://` URL with an `https://`
    /// URL in the same payload). Mixing file URLs and web URLs causes `sharingd`
    /// (`AirDropNWClient: Mixed content: 1 file URLs, 1 non-file URLs`) to close the
    /// transfer connection after the ASK phase, failing the PDF UPLOAD phase.
    @MainActor
    static func presentShareSheet(for recipe: RecipeData, item: StashItem? = nil, anchorView: NSView? = nil) {
        guard let fileURL = stagePDFFile(for: recipe, item: item) else {
            ToastCenter.shared.show("Couldn't generate Recipe PDF", kind: .error)
            return
        }
        guard let view = anchorView ?? NSApp.keyWindow?.contentView else { return }
        let picker = NSSharingServicePicker(items: [fileURL])
        activeSharePicker = picker
        let anchorRect = anchorView != nil
            ? view.bounds
            : NSRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        picker.show(relativeTo: anchorRect, of: view, preferredEdge: .minY)
    }

    // MARK: - Two-Pass Layout & Drawing Engine

    private static func performLayout(
        recipe: RecipeData,
        item: StashItem?,
        heroImage: NSImage?,
        context: CGContext?,
        totalPages: Int
    ) -> Int {
        var currentPage = 0

        func beginNewPage() {
            if currentPage > 0, let ctx = context {
                drawPageFooter(ctx: ctx, recipe: recipe, item: item, pageNumber: currentPage, totalPages: totalPages)
                NSGraphicsContext.restoreGraphicsState()
                ctx.endPDFPage()
            }
            currentPage += 1
            if let ctx = context {
                ctx.beginPDFPage(nil)
                // Flip coordinate system so (0, 0) is top-left and Y grows downward.
                ctx.translateBy(x: 0, y: pageHeight)
                ctx.scaleBy(x: 1, y: -1)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)

                drawPageChrome(isFirstPage: currentPage == 1)
            }
        }

        beginNewPage()
        var cursorY: CGFloat = topMargin

        // 1. Editorial Header Block (Page 1)
        cursorY = drawHeaderBlock(recipe: recipe, item: item, heroImage: heroImage, startY: cursorY, isDryRun: context == nil)
        cursorY += 14

        // 2. Metadata Strip (Prep / Cook / Total / Yield / Cooked)
        let metaColumns = buildMetadataColumns(recipe: recipe)
        if !metaColumns.isEmpty {
            cursorY = drawMetadataStrip(columns: metaColumns, startY: cursorY, isDryRun: context == nil)
            cursorY += 18
        } else {
            // Subtle warm divider when no metadata strip is present
            if context != nil {
                borderColor.setFill()
                NSBezierPath(rect: NSRect(x: marginX, y: cursorY, width: contentWidth, height: 1)).fill()
            }
            cursorY += 14
        }

        // 3. Two-Column Body: Ingredients (Left) + Instructions (Right)
        let bodyStartY = cursorY
        let hasIngredients = !recipe.ingredients.isEmpty
        let hasInstructions = !recipe.instructions.isEmpty

        if hasIngredients && hasInstructions {
            // Pre-group ingredients and instructions into renderable items
            let ingItems = buildIngredientRenderItems(recipe.ingredients)
            let stepItems = buildInstructionRenderItems(recipe.instructions)

            var ingIdx = 0
            var stepIdx = 0
            var pageStartTopY = bodyStartY

            while ingIdx < ingItems.count || stepIdx < stepItems.count {
                var leftY = pageStartTopY
                var rightY = pageStartTopY

                // Draw Ingredients column on this page
                if ingIdx < ingItems.count {
                    let headerTitle = ingIdx == 0 ? "INGREDIENTS" : "INGREDIENTS (CONT.)"
                    leftY = drawColumnSectionHeader(title: headerTitle, x: marginX, y: leftY, width: leftColWidth, isDryRun: context == nil)
                    leftY += 8

                    while ingIdx < ingItems.count {
                        let itemHeight = measureIngredientItem(ingItems[ingIdx], width: leftColWidth)
                        if leftY + itemHeight > maxContentY && leftY > pageStartTopY + 36 {
                            break
                        }
                        drawIngredientItem(ingItems[ingIdx], x: marginX, y: leftY, width: leftColWidth, isDryRun: context == nil)
                        leftY += itemHeight
                        ingIdx += 1
                    }
                }

                // Draw Instructions column on this page
                // If all ingredients were already completed on a previous page, let instructions use full width!
                let useFullWidthForSteps = (ingIdx >= ingItems.count && leftY == pageStartTopY)
                let stepColX = useFullWidthForSteps ? marginX : rightColX
                let stepColW = useFullWidthForSteps ? contentWidth : rightColWidth

                if stepIdx < stepItems.count {
                    let headerTitle = stepIdx == 0 ? "PREPARATION" : "PREPARATION (CONT.)"
                    rightY = drawColumnSectionHeader(title: headerTitle, x: stepColX, y: rightY, width: stepColW, isDryRun: context == nil)
                    rightY += 10

                    while stepIdx < stepItems.count {
                        let stepHeight = measureInstructionItem(stepItems[stepIdx], width: stepColW)
                        if rightY + stepHeight > maxContentY && rightY > pageStartTopY + 36 {
                            break
                        }
                        drawInstructionItem(stepItems[stepIdx], x: stepColX, y: rightY, width: stepColW, isDryRun: context == nil)
                        rightY += stepHeight
                        stepIdx += 1
                    }
                }

                // Draw subtle vertical column separator when both columns were active on this page
                if !useFullWidthForSteps && context != nil {
                    let sepX = marginX + leftColWidth + colGutter / 2
                    let sepBottom = max(leftY, rightY)
                    if sepBottom > pageStartTopY + 10 {
                        borderColor.withAlphaComponent(0.75).setFill()
                        NSBezierPath(rect: NSRect(x: sepX, y: pageStartTopY, width: 0.75, height: sepBottom - pageStartTopY)).fill()
                    }
                }

                cursorY = max(leftY, rightY)

                if ingIdx < ingItems.count || stepIdx < stepItems.count {
                    beginNewPage()
                    pageStartTopY = topMargin
                    cursorY = topMargin
                }
            }
        } else if hasIngredients {
            // Full-width ingredients only
            let ingItems = buildIngredientRenderItems(recipe.ingredients)
            cursorY = drawColumnSectionHeader(title: "INGREDIENTS", x: marginX, y: cursorY, width: contentWidth, isDryRun: context == nil)
            cursorY += 8
            for ing in ingItems {
                let h = measureIngredientItem(ing, width: contentWidth)
                if cursorY + h > maxContentY {
                    beginNewPage()
                    cursorY = topMargin
                    cursorY = drawColumnSectionHeader(title: "INGREDIENTS (CONT.)", x: marginX, y: cursorY, width: contentWidth, isDryRun: context == nil)
                    cursorY += 8
                }
                drawIngredientItem(ing, x: marginX, y: cursorY, width: contentWidth, isDryRun: context == nil)
                cursorY += h
            }
        } else if hasInstructions {
            // Full-width instructions only
            let stepItems = buildInstructionRenderItems(recipe.instructions)
            cursorY = drawColumnSectionHeader(title: "PREPARATION", x: marginX, y: cursorY, width: contentWidth, isDryRun: context == nil)
            cursorY += 10
            for step in stepItems {
                let h = measureInstructionItem(step, width: contentWidth)
                if cursorY + h > maxContentY {
                    beginNewPage()
                    cursorY = topMargin
                    cursorY = drawColumnSectionHeader(title: "PREPARATION (CONT.)", x: marginX, y: cursorY, width: contentWidth, isDryRun: context == nil)
                    cursorY += 10
                }
                drawInstructionItem(step, x: marginX, y: cursorY, width: contentWidth, isDryRun: context == nil)
                cursorY += h
            }
        }

        // 4. Nutrition Strip (if present)
        if let nutrition = recipe.nutrition, !nutrition.isEmpty {
            let nutHeight = measureNutritionBlock(nutrition: nutrition, width: contentWidth)
            if cursorY + 18 + nutHeight > maxContentY {
                beginNewPage()
                cursorY = topMargin
            } else {
                cursorY += 18
            }
            cursorY = drawNutritionBlock(nutrition: nutrition, startY: cursorY, width: contentWidth, isDryRun: context == nil)
        }

        // 5. Kitchen Cook Log (if present)
        if !recipe.cookHistory.isEmpty {
            let logHeight = measureCookLogBlock(entries: recipe.cookHistory, width: contentWidth)
            if cursorY + 18 + logHeight > maxContentY {
                beginNewPage()
                cursorY = topMargin
            } else {
                cursorY += 18
            }
            cursorY = drawCookLogBlock(entries: recipe.cookHistory, startY: cursorY, width: contentWidth, isDryRun: context == nil)
        }

        // Close final page
        if let ctx = context {
            drawPageFooter(ctx: ctx, recipe: recipe, item: item, pageNumber: currentPage, totalPages: totalPages)
            NSGraphicsContext.restoreGraphicsState()
            ctx.endPDFPage()
        }

        return currentPage
    }

    // MARK: - Page Background & Chrome

    private static func drawPageChrome(isFirstPage: Bool) {
        // Warm paper background
        pageBgColor.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: pageWidth, height: pageHeight)).fill()

        // Delicate outer frame hairline
        let frameInset: CGFloat = 18
        let frameRect = NSRect(
            x: frameInset,
            y: frameInset,
            width: pageWidth - frameInset * 2,
            height: pageHeight - frameInset * 2
        )
        borderColor.withAlphaComponent(0.6).setStroke()
        let borderPath = NSBezierPath(roundedRect: frameRect, xRadius: 4, yRadius: 4)
        borderPath.lineWidth = 0.75
        borderPath.stroke()

        // Rich terracotta top banner accent on Page 1 (subtle thin bar on continuation pages)
        terracotta.setFill()
        let barHeight: CGFloat = isFirstPage ? 6.0 : 3.0
        NSBezierPath(rect: NSRect(x: frameInset, y: frameInset, width: pageWidth - frameInset * 2, height: barHeight)).fill()
    }

    // MARK: - Header Block

    private static func drawHeaderBlock(
        recipe: RecipeData,
        item: StashItem?,
        heroImage: NSImage?,
        startY: CGFloat,
        isDryRun: Bool
    ) -> CGFloat {
        let imageSize: CGFloat = heroImage != nil ? 112 : 0
        let imageGap: CGFloat = heroImage != nil ? 18 : 0
        let textWidth = contentWidth - imageSize - imageGap

        var y = startY

        // Eyebrow pill row: [STASH RECIPE] [CUISINE] [CATEGORY]
        let pillHeight: CGFloat = 17
        if !isDryRun {
            var pillX = marginX
            pillX = drawBadgePill(
                text: "STASH RECIPE",
                x: pillX,
                y: y,
                height: pillHeight,
                bgColor: terracotta,
                textColor: .white
            ) + 6

            if let cuisine = recipe.cuisine?.trimmingCharacters(in: .whitespacesAndNewlines), !cuisine.isEmpty {
                pillX = drawBadgePill(
                    text: cuisine.uppercased(),
                    x: pillX,
                    y: y,
                    height: pillHeight,
                    bgColor: terracottaSoft,
                    textColor: terracotta
                ) + 6
            }

            if let category = recipe.category?.trimmingCharacters(in: .whitespacesAndNewlines), !category.isEmpty {
                _ = drawBadgePill(
                    text: category.uppercased(),
                    x: pillX,
                    y: y,
                    height: pillHeight,
                    bgColor: cardBgColor,
                    textColor: inkSecondary
                )
            }
        }
        y += pillHeight + 9

        // Editorial Serif Title
        let titleText = recipe.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (item?.title ?? "Untitled Recipe")
            : recipe.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let titleFont = editorialSerifFont(size: 24, weight: .bold)
        let titleAttr = attributedText(
            titleText,
            font: titleFont,
            color: inkPrimary,
            lineSpacing: 2.0
        )
        let titleHeight = measureAttributed(titleAttr, width: textWidth)
        if !isDryRun {
            titleAttr.draw(
                with: NSRect(x: marginX, y: y, width: textWidth, height: titleHeight),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
        }
        y += titleHeight + 5

        // Author + Source Domain Byline
        var bylineParts: [String] = []
        if let author = recipe.author?.trimmingCharacters(in: .whitespacesAndNewlines), !author.isEmpty {
            bylineParts.append("By \(author)")
        }
        if let rawURL = recipe.sourceURL ?? item?.url,
           let host = URL(string: rawURL)?.host?.replacingOccurrences(of: "www.", with: ""),
           !host.isEmpty {
            bylineParts.append(host)
        }
        if !bylineParts.isEmpty {
            let bylineString = bylineParts.joined(separator: "  ·  ")
            let bylineAttr = attributedText(
                bylineString,
                font: .systemFont(ofSize: 11, weight: .medium),
                color: inkSecondary
            )
            let bylineH = measureAttributed(bylineAttr, width: textWidth)
            if !isDryRun {
                bylineAttr.draw(
                    with: NSRect(x: marginX, y: y, width: textWidth, height: bylineH),
                    options: [.usesLineFragmentOrigin, .usesFontLeading]
                )
            }
            y += bylineH + 6
        }

        // Description / Headnote (Italic Serif)
        if let desc = recipe.description?.trimmingCharacters(in: .whitespacesAndNewlines), !desc.isEmpty {
            // Clamp overly long scraped descriptions so Page 1 remains balanced
            let clippedDesc = desc.count > 420 ? String(desc.prefix(417)) + "…" : desc
            let descFont = editorialSerifItalicFont(size: 10.8)
            let descAttr = attributedText(
                clippedDesc,
                font: descFont,
                color: inkSecondary,
                lineSpacing: 2.5
            )
            let descH = measureAttributed(descAttr, width: textWidth)
            if !isDryRun {
                descAttr.draw(
                    with: NSRect(x: marginX, y: y, width: textWidth, height: descH),
                    options: [.usesLineFragmentOrigin, .usesFontLeading]
                )
            }
            y += descH + 4
        }

        // Hero Image (Right-aligned in Header)
        if let heroImage {
            let imgX = marginX + contentWidth - imageSize
            let imgY = startY
            if !isDryRun {
                let imgRect = NSRect(x: imgX, y: imgY, width: imageSize, height: imageSize)
                drawRoundedAspectFillImage(heroImage, in: imgRect, cornerRadius: 10)
            }
            y = max(y, startY + imageSize + 4)
        }

        return y
    }

    private static func drawBadgePill(
        text: String,
        x: CGFloat,
        y: CGFloat,
        height: CGFloat,
        bgColor: NSColor,
        textColor: NSColor
    ) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 8.5, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .kern: 0.7
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let textSize = str.size()
        let padX: CGFloat = 8
        let pillW = ceil(textSize.width) + padX * 2
        let pillRect = NSRect(x: x, y: y, width: pillW, height: height)

        bgColor.setFill()
        NSBezierPath(roundedRect: pillRect, xRadius: height / 2, yRadius: height / 2).fill()

        let textY = y + (height - textSize.height) / 2
        str.draw(at: NSPoint(x: x + padX, y: textY))
        return x + pillW
    }

    // MARK: - Metadata Strip

    private struct MetaColumn {
        let label: String
        let value: String
    }

    private static func buildMetadataColumns(recipe: RecipeData) -> [MetaColumn] {
        var cols: [MetaColumn] = []
        if let prep = recipe.prepTime?.trimmingCharacters(in: .whitespacesAndNewlines), !prep.isEmpty {
            cols.append(MetaColumn(label: "PREP TIME", value: prep))
        }
        if let cook = recipe.cookTime?.trimmingCharacters(in: .whitespacesAndNewlines), !cook.isEmpty {
            cols.append(MetaColumn(label: "COOK TIME", value: cook))
        }
        if let total = recipe.totalTime?.trimmingCharacters(in: .whitespacesAndNewlines), !total.isEmpty {
            cols.append(MetaColumn(label: "TOTAL TIME", value: total))
        }
        if let yieldVal = recipe.yield?.trimmingCharacters(in: .whitespacesAndNewlines), !yieldVal.isEmpty {
            cols.append(MetaColumn(label: "YIELD", value: yieldVal))
        }
        if !recipe.cookHistory.isEmpty {
            let count = recipe.cookHistory.count
            let ratings = recipe.cookHistory.compactMap(\.rating).filter { $0 >= 1 && $0 <= 5 }
            if !ratings.isEmpty {
                let avg = Double(ratings.reduce(0, +)) / Double(ratings.count)
                cols.append(MetaColumn(label: "COOKED", value: String(format: "%d× (★ %.1f)", count, avg)))
            } else {
                cols.append(MetaColumn(label: "COOKED", value: "\(count)×"))
            }
        }
        return cols
    }

    private static func drawMetadataStrip(columns: [MetaColumn], startY: CGFloat, isDryRun: Bool) -> CGFloat {
        let stripHeight: CGFloat = 46
        guard !isDryRun else { return startY + stripHeight }

        let rect = NSRect(x: marginX, y: startY, width: contentWidth, height: stripHeight)
        cardBgColor.setFill()
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        path.fill()

        borderColor.setStroke()
        path.lineWidth = 1
        path.stroke()

        let colWidth = contentWidth / CGFloat(columns.count)
        for (idx, col) in columns.enumerated() {
            let cellX = marginX + CGFloat(idx) * colWidth
            if idx > 0 {
                borderColor.setFill()
                NSBezierPath(rect: NSRect(x: cellX, y: startY + 9, width: 1, height: stripHeight - 18)).fill()
            }

            let labelAttr = attributedText(
                col.label,
                font: .systemFont(ofSize: 8.0, weight: .bold),
                color: inkTertiary,
                alignment: .center,
                kern: 0.6
            )
            labelAttr.draw(
                with: NSRect(x: cellX + 6, y: startY + 9, width: colWidth - 12, height: 12),
                options: [.usesLineFragmentOrigin]
            )

            let valAttr = attributedText(
                col.value,
                font: .systemFont(ofSize: 11.5, weight: .bold),
                color: inkPrimary,
                alignment: .center
            )
            valAttr.draw(
                with: NSRect(x: cellX + 6, y: startY + 23, width: colWidth - 12, height: 16),
                options: [.usesLineFragmentOrigin]
            )
        }

        return startY + stripHeight
    }

    // MARK: - Section Headers

    private static func drawColumnSectionHeader(
        title: String,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        isDryRun: Bool
    ) -> CGFloat {
        let headerH: CGFloat = 20
        guard !isDryRun else { return y + headerH }

        let attr = attributedText(
            title,
            font: .systemFont(ofSize: 10.5, weight: .heavy),
            color: inkPrimary,
            kern: 1.0
        )
        attr.draw(with: NSRect(x: x, y: y, width: width, height: 14), options: [.usesLineFragmentOrigin])

        // Terracotta accent bar + warm rule
        terracotta.setFill()
        NSBezierPath(rect: NSRect(x: x, y: y + 16, width: 28, height: 2.2)).fill()

        borderColor.setFill()
        NSBezierPath(rect: NSRect(x: x + 28, y: y + 17, width: max(0, width - 28), height: 0.8)).fill()

        return y + headerH
    }

    // MARK: - Ingredients Rendering

    private enum IngredientRenderItem {
        case sectionHeader(String)
        case ingredient(String)
    }

    private static func buildIngredientRenderItems(_ ingredients: [RecipeIngredient]) -> [IngredientRenderItem] {
        var result: [IngredientRenderItem] = []
        var currentSection: String? = nil
        for ing in ingredients {
            if let sec = ing.section?.trimmingCharacters(in: .whitespacesAndNewlines),
               !sec.isEmpty,
               sec != currentSection {
                currentSection = sec
                result.append(.sectionHeader(sec))
            }
            let cleaned = ing.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                result.append(.ingredient(cleaned))
            }
        }
        return result
    }

    private static func measureIngredientItem(_ item: IngredientRenderItem, width: CGFloat) -> CGFloat {
        switch item {
        case .sectionHeader(let title):
            let attr = attributedText(
                title.uppercased(),
                font: .systemFont(ofSize: 9.0, weight: .bold),
                color: terracotta,
                kern: 0.5
            )
            return measureAttributed(attr, width: width) + 10
        case .ingredient(let text):
            let textW = width - 18
            let attr = attributedText(
                text,
                font: .systemFont(ofSize: 10.0, weight: .regular),
                color: inkPrimary,
                lineSpacing: 2.0
            )
            return max(14, measureAttributed(attr, width: textW)) + 6
        }
    }

    private static func drawIngredientItem(
        _ item: IngredientRenderItem,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        isDryRun: Bool
    ) {
        guard !isDryRun else { return }
        switch item {
        case .sectionHeader(let title):
            let attr = attributedText(
                title.uppercased(),
                font: .systemFont(ofSize: 9.0, weight: .bold),
                color: terracotta,
                kern: 0.5
            )
            let h = measureAttributed(attr, width: width)
            attr.draw(with: NSRect(x: x, y: y + 4, width: width, height: h), options: [.usesLineFragmentOrigin, .usesFontLeading])

        case .ingredient(let text):
            // Crisp vector circular checkbox
            let boxSize: CGFloat = 8.5
            let boxRect = NSRect(x: x + 1, y: y + 2.5, width: boxSize, height: boxSize)
            terracotta.withAlphaComponent(0.65).setStroke()
            let circle = NSBezierPath(ovalIn: boxRect)
            circle.lineWidth = 1.1
            circle.stroke()

            let textX = x + 16
            let textW = width - 16
            let attr = attributedText(
                text,
                font: .systemFont(ofSize: 10.0, weight: .regular),
                color: inkPrimary,
                lineSpacing: 2.0
            )
            let h = measureAttributed(attr, width: textW)
            attr.draw(with: NSRect(x: textX, y: y, width: textW, height: h), options: [.usesLineFragmentOrigin, .usesFontLeading])
        }
    }

    // MARK: - Instructions Rendering

    private enum InstructionRenderItem {
        case sectionHeader(String)
        case step(number: Int, title: String?, body: String)
    }

    private static func buildInstructionRenderItems(_ instructions: [RecipeInstruction]) -> [InstructionRenderItem] {
        var result: [InstructionRenderItem] = []
        var currentSection: String? = nil
        for (idx, step) in instructions.enumerated() {
            if let sec = step.section?.trimmingCharacters(in: .whitespacesAndNewlines),
               !sec.isEmpty,
               sec != currentSection {
                currentSection = sec
                result.append(.sectionHeader(sec))
            }
            let num = step.stepNumber > 0 ? step.stepNumber : (idx + 1)
            let body = step.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty {
                result.append(.step(number: num, title: step.displayTitle, body: body))
            }
        }
        return result
    }

    private static func measureInstructionItem(_ item: InstructionRenderItem, width: CGFloat) -> CGFloat {
        switch item {
        case .sectionHeader(let title):
            let attr = attributedText(
                title.uppercased(),
                font: .systemFont(ofSize: 9.5, weight: .bold),
                color: terracotta,
                kern: 0.6
            )
            return measureAttributed(attr, width: width) + 12
        case .step(_, let title, let body):
            let textW = width - 28
            let combined = buildStepAttributedString(title: title, body: body)
            let textH = measureAttributed(combined, width: textW)
            return max(22, textH) + 11
        }
    }

    private static func drawInstructionItem(
        _ item: InstructionRenderItem,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        isDryRun: Bool
    ) {
        guard !isDryRun else { return }
        switch item {
        case .sectionHeader(let title):
            let attr = attributedText(
                title.uppercased(),
                font: .systemFont(ofSize: 9.5, weight: .bold),
                color: terracotta,
                kern: 0.6
            )
            let h = measureAttributed(attr, width: width)
            attr.draw(with: NSRect(x: x, y: y + 4, width: width, height: h), options: [.usesLineFragmentOrigin, .usesFontLeading])

        case .step(let number, let title, let body):
            // Terracotta numbered circle badge
            let badgeSize: CGFloat = 19
            let badgeRect = NSRect(x: x, y: y + 1, width: badgeSize, height: badgeSize)
            terracotta.setFill()
            NSBezierPath(ovalIn: badgeRect).fill()

            let numStr = "\(number)"
            let numAttr = attributedText(
                numStr,
                font: .systemFont(ofSize: number >= 10 ? 9.0 : 10.0, weight: .bold),
                color: .white,
                alignment: .center
            )
            let numSize = numAttr.size()
            let numY = badgeRect.minY + (badgeSize - numSize.height) / 2
            numAttr.draw(with: NSRect(x: x, y: numY, width: badgeSize, height: numSize.height), options: [.usesLineFragmentOrigin])

            // Step title + body text
            let textX = x + 28
            let textW = width - 28
            let combined = buildStepAttributedString(title: title, body: body)
            let textH = measureAttributed(combined, width: textW)
            combined.draw(with: NSRect(x: textX, y: y, width: textW, height: textH), options: [.usesLineFragmentOrigin, .usesFontLeading])
        }
    }

    private static func buildStepAttributedString(title: String?, body: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        para.lineSpacing = 3.0

        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty,
           !body.lowercased().hasPrefix(title.lowercased()) {
            let cleanTitle = title.hasSuffix(":") || title.hasSuffix(".") ? "\(title) " : "\(title): "
            result.append(NSAttributedString(string: cleanTitle, attributes: [
                .font: NSFont.systemFont(ofSize: 10.5, weight: .bold),
                .foregroundColor: inkPrimary,
                .paragraphStyle: para
            ]))
        }

        result.append(NSAttributedString(string: body, attributes: [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .regular),
            .foregroundColor: inkPrimary,
            .paragraphStyle: para
        ]))
        return result
    }

    // MARK: - Nutrition Block

    private static func measureNutritionBlock(nutrition: [String: String], width: CGFloat) -> CGFloat {
        let pairs = nutrition.sorted { $0.key < $1.key }
        let summary = pairs.map { "\($0.key.capitalized): \($0.value)" }.joined(separator: "   ·   ")
        let attr = attributedText(summary, font: .systemFont(ofSize: 9.5, weight: .medium), color: inkSecondary, lineSpacing: 2.0)
        return measureAttributed(attr, width: width - 24) + 34
    }

    private static func drawNutritionBlock(
        nutrition: [String: String],
        startY: CGFloat,
        width: CGFloat,
        isDryRun: Bool
    ) -> CGFloat {
        let blockH = measureNutritionBlock(nutrition: nutrition, width: width)
        guard !isDryRun else { return startY + blockH }

        let rect = NSRect(x: marginX, y: startY, width: width, height: blockH)
        sidebarBgColor.setFill()
        let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        path.fill()
        borderColor.setStroke()
        path.lineWidth = 0.8
        path.stroke()

        let titleAttr = attributedText(
            "NUTRITION PER SERVING",
            font: .systemFont(ofSize: 8.5, weight: .bold),
            color: terracotta,
            kern: 0.7
        )
        titleAttr.draw(with: NSRect(x: marginX + 12, y: startY + 8, width: width - 24, height: 12), options: [.usesLineFragmentOrigin])

        let pairs = nutrition.sorted { $0.key < $1.key }
        let richLine = NSMutableAttributedString()
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        para.lineSpacing = 2.0

        for (idx, pair) in pairs.enumerated() {
            if idx > 0 {
                richLine.append(NSAttributedString(string: "   ·   ", attributes: [
                    .font: NSFont.systemFont(ofSize: 9.5, weight: .regular),
                    .foregroundColor: inkTertiary,
                    .paragraphStyle: para
                ]))
            }
            richLine.append(NSAttributedString(string: "\(pair.key.capitalized): ", attributes: [
                .font: NSFont.systemFont(ofSize: 9.5, weight: .semibold),
                .foregroundColor: inkSecondary,
                .paragraphStyle: para
            ]))
            richLine.append(NSAttributedString(string: pair.value, attributes: [
                .font: NSFont.systemFont(ofSize: 9.5, weight: .bold),
                .foregroundColor: inkPrimary,
                .paragraphStyle: para
            ]))
        }

        let textH = measureAttributed(richLine, width: width - 24)
        richLine.draw(
            with: NSRect(x: marginX + 12, y: startY + 23, width: width - 24, height: textH),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )

        return startY + blockH
    }

    // MARK: - Kitchen Cook Log Block

    private static func measureCookLogBlock(entries: [RecipeCookEntry], width: CGFloat) -> CGFloat {
        var total: CGFloat = 28
        for entry in entries.prefix(6) {
            let lineAttr = buildCookLogEntryAttributed(entry)
            total += measureAttributed(lineAttr, width: width - 24) + 6
        }
        return total + 8
    }

    private static func drawCookLogBlock(
        entries: [RecipeCookEntry],
        startY: CGFloat,
        width: CGFloat,
        isDryRun: Bool
    ) -> CGFloat {
        let blockH = measureCookLogBlock(entries: entries, width: width)
        guard !isDryRun else { return startY + blockH }

        let rect = NSRect(x: marginX, y: startY, width: width, height: blockH)
        cardBgColor.withAlphaComponent(0.75).setFill()
        let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        path.fill()
        borderColor.setStroke()
        path.lineWidth = 0.8
        path.stroke()

        let headerAttr = attributedText(
            "KITCHEN COOK LOG (\(entries.count))",
            font: .systemFont(ofSize: 8.5, weight: .bold),
            color: terracotta,
            kern: 0.7
        )
        headerAttr.draw(with: NSRect(x: marginX + 12, y: startY + 8, width: width - 24, height: 12), options: [.usesLineFragmentOrigin])

        var rowY = startY + 24
        for entry in entries.prefix(6) {
            let lineAttr = buildCookLogEntryAttributed(entry)
            let h = measureAttributed(lineAttr, width: width - 24)
            lineAttr.draw(
                with: NSRect(x: marginX + 12, y: rowY, width: width - 24, height: h),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
            rowY += h + 6
        }

        return startY + blockH
    }

    private static func buildCookLogEntryAttributed(_ entry: RecipeCookEntry) -> NSAttributedString {
        let res = NSMutableAttributedString()
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        para.lineSpacing = 1.5

        res.append(NSAttributedString(string: "• \(entry.formattedDate)", attributes: [
            .font: NSFont.systemFont(ofSize: 9.5, weight: .semibold),
            .foregroundColor: inkPrimary,
            .paragraphStyle: para
        ]))

        if let stars = entry.formattedStars {
            res.append(NSAttributedString(string: "   \(stars)", attributes: [
                .font: NSFont.systemFont(ofSize: 9.5, weight: .bold),
                .foregroundColor: starAmber,
                .paragraphStyle: para
            ]))
        }

        if let note = entry.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            res.append(NSAttributedString(string: "  —  \"\(note)\"", attributes: [
                .font: editorialSerifItalicFont(size: 9.5),
                .foregroundColor: inkSecondary,
                .paragraphStyle: para
            ]))
        }

        return res
    }

    // MARK: - Page Footer

    private static func drawPageFooter(
        ctx: CGContext,
        recipe: RecipeData,
        item: StashItem?,
        pageNumber: Int,
        totalPages: Int
    ) {
        let footerY = pageHeight - 36
        borderColor.setFill()
        NSBezierPath(rect: NSRect(x: marginX, y: footerY - 6, width: contentWidth, height: 0.75)).fill()

        var leftText = "Stash Recipe Card"
        if let rawURL = recipe.sourceURL ?? item?.url, !rawURL.isEmpty {
            let cleanURL = rawURL.count > 72 ? String(rawURL.prefix(69)) + "…" : rawURL
            leftText += "  ·  \(cleanURL)"
        }

        let leftAttr = attributedText(
            leftText,
            font: .systemFont(ofSize: 8.5, weight: .regular),
            color: inkTertiary
        )
        leftAttr.draw(with: NSRect(x: marginX, y: footerY, width: contentWidth - 90, height: 14), options: [.usesLineFragmentOrigin])

        let pageStr = "Page \(pageNumber) of \(totalPages)"
        let rightAttr = attributedText(
            pageStr,
            font: .systemFont(ofSize: 8.5, weight: .semibold),
            color: inkTertiary,
            alignment: .right
        )
        rightAttr.draw(with: NSRect(x: marginX + contentWidth - 90, y: footerY, width: 90, height: 14), options: [.usesLineFragmentOrigin])
    }

    // MARK: - Typography & Image Helpers

    private static func editorialSerifFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let sys = NSFont.systemFont(ofSize: size, weight: weight)
        if let desc = sys.fontDescriptor.withDesign(.serif),
           let serif = NSFont(descriptor: desc, size: size) {
            return serif
        }
        return NSFont(name: "Georgia-Bold", size: size) ?? sys
    }

    private static func editorialSerifItalicFont(size: CGFloat) -> NSFont {
        if let georgiaItalic = NSFont(name: "Georgia-Italic", size: size) {
            return georgiaItalic
        }
        let sys = NSFont.systemFont(ofSize: size, weight: .regular)
        if let desc = sys.fontDescriptor.withDesign(.serif)?.withSymbolicTraits(.italic),
           let italic = NSFont(descriptor: desc, size: size) {
            return italic
        }
        return sys
    }

    private static func attributedText(
        _ text: String,
        font: NSFont,
        color: NSColor,
        alignment: NSTextAlignment = .left,
        lineSpacing: CGFloat = 0,
        kern: CGFloat = 0
    ) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.alignment = alignment
        para.lineBreakMode = .byWordWrapping
        para.lineSpacing = lineSpacing
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: para
        ]
        if kern != 0 {
            attrs[.kern] = kern
        }
        return NSAttributedString(string: text, attributes: attrs)
    }

    private static func measureAttributed(_ attr: NSAttributedString, width: CGFloat) -> CGFloat {
        guard attr.length > 0 else { return 0 }
        let rect = attr.boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return ceil(rect.height) + 2
    }

    private static func loadHeroImage(for item: StashItem?) -> NSImage? {
        guard let item else { return nil }
        // 1. If the item is an image blob itself, prefer the full-res storePath
        if item.type == .image,
           let storePath = item.storePath,
           let url = FilePathResolver.resolve(storePath: storePath),
           let img = NSImage(contentsOf: url) {
            return img
        }
        // 2. Otherwise check the item's thumbnailPath (automatically populated from recipe.imageURL)
        if let rel = item.thumbnailPath,
           !rel.isEmpty,
           let url = FilePathResolver.resolveRelative(rel),
           FileManager.default.fileExists(atPath: url.path),
           let img = NSImage(contentsOf: url) {
            return img
        }
        // 3. Fallback: check storePath if it happens to be an image
        if let storePath = item.storePath,
           let url = FilePathResolver.resolve(storePath: storePath),
           let img = NSImage(contentsOf: url) {
            return img
        }
        return nil
    }

    private static func drawRoundedAspectFillImage(_ image: NSImage, in rect: NSRect, cornerRadius: CGFloat) {
        let imgSize = image.size
        guard imgSize.width > 0, imgSize.height > 0 else { return }

        NSGraphicsContext.current?.saveGraphicsState()
        let clipPath = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
        clipPath.addClip()

        let scale = max(rect.width / imgSize.width, rect.height / imgSize.height)
        let drawW = imgSize.width * scale
        let drawH = imgSize.height * scale
        let dx = rect.origin.x + (rect.width - drawW) / 2
        let dy = rect.origin.y + (rect.height - drawH) / 2

        image.draw(
            in: NSRect(x: dx, y: dy, width: drawW, height: drawH),
            from: .zero,
            operation: .sourceOver,
            fraction: 1.0,
            respectFlipped: true,
            hints: nil
        )
        NSGraphicsContext.current?.restoreGraphicsState()

        // Warm subtle border around the hero photo
        borderColor.setStroke()
        let border = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
        border.lineWidth = 1.0
        border.stroke()
    }

    private static func slugify(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "recipe" }
        let allowed = CharacterSet.alphanumerics
        var out = ""
        var prevDash = false
        for scalar in trimmed.lowercased().unicodeScalars {
            if allowed.contains(scalar) {
                out.unicodeScalars.append(scalar)
                prevDash = false
            } else if !prevDash && !out.isEmpty {
                out.append("-")
                prevDash = true
            }
            if out.count >= 60 { break }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "recipe" : out
    }
}
