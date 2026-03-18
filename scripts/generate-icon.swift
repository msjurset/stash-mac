#!/usr/bin/env swift

import AppKit
import CoreGraphics

/// Generates a macOS app icon with a stash/vault design.
func renderIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    guard let context = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }

    let inset = size * 0.05
    let roundedRect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let cornerRadius = size * 0.22

    // Background: deep blue-purple gradient
    let bgPath = CGPath(roundedRect: roundedRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    context.addPath(bgPath)
    context.clip()

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bgColors = [
        CGColor(red: 0.13, green: 0.11, blue: 0.22, alpha: 1.0),
        CGColor(red: 0.06, green: 0.05, blue: 0.14, alpha: 1.0),
    ]
    if let gradient = CGGradient(colorsSpace: colorSpace, colors: bgColors as CFArray, locations: [0.0, 1.0]) {
        context.drawLinearGradient(gradient,
                                   start: CGPoint(x: 0, y: size),
                                   end: CGPoint(x: size, y: 0),
                                   options: [])
    }

    let center = CGPoint(x: size / 2, y: size / 2)

    // Tray/box shape — open-top container representing a stash
    let trayWidth = size * 0.52
    let trayHeight = size * 0.36
    let trayBottom = center.y - trayHeight * 0.42
    let trayLeft = center.x - trayWidth / 2
    let trayCorner = size * 0.04
    let wallSlant = size * 0.03  // slight outward slant

    let trayPath = CGMutablePath()
    // Bottom-left corner
    trayPath.move(to: CGPoint(x: trayLeft + wallSlant, y: trayBottom + trayCorner))
    trayPath.addArc(tangent1End: CGPoint(x: trayLeft + wallSlant, y: trayBottom),
                    tangent2End: CGPoint(x: trayLeft + wallSlant + trayCorner, y: trayBottom),
                    radius: trayCorner)
    // Bottom-right corner
    let trayRight = trayLeft + trayWidth
    trayPath.addLine(to: CGPoint(x: trayRight - wallSlant - trayCorner, y: trayBottom))
    trayPath.addArc(tangent1End: CGPoint(x: trayRight - wallSlant, y: trayBottom),
                    tangent2End: CGPoint(x: trayRight - wallSlant, y: trayBottom + trayCorner),
                    radius: trayCorner)
    // Right wall (slanted outward)
    trayPath.addLine(to: CGPoint(x: trayRight, y: trayBottom + trayHeight))
    // Left wall (slanted outward)
    trayPath.addLine(to: CGPoint(x: trayLeft, y: trayBottom + trayHeight))
    trayPath.closeSubpath()

    // Tray fill with subtle gradient
    context.saveGState()
    context.addPath(trayPath)
    context.clip()
    let trayColors = [
        CGColor(red: 0.35, green: 0.28, blue: 0.65, alpha: 0.7),
        CGColor(red: 0.22, green: 0.18, blue: 0.45, alpha: 0.7),
    ]
    if let trayGradient = CGGradient(colorsSpace: colorSpace, colors: trayColors as CFArray, locations: [0.0, 1.0]) {
        context.drawLinearGradient(trayGradient,
                                   start: CGPoint(x: 0, y: trayBottom + trayHeight),
                                   end: CGPoint(x: 0, y: trayBottom),
                                   options: [])
    }
    context.restoreGState()

    // Tray outline
    context.addPath(trayPath)
    context.setStrokeColor(CGColor(red: 0.55, green: 0.45, blue: 0.90, alpha: 0.6))
    context.setLineWidth(size * 0.012)
    context.strokePath()

    // Stacked cards inside the tray (representing stored items)
    let cardWidth = trayWidth * 0.65
    let cardHeight = size * 0.05
    let cardCorner = size * 0.015
    let cardColors: [(r: CGFloat, g: CGFloat, b: CGFloat)] = [
        (0.45, 0.87, 0.62),  // green (bottom)
        (0.40, 0.72, 0.95),  // blue (middle)
        (0.95, 0.68, 0.38),  // amber (top)
    ]

    for (i, color) in cardColors.enumerated() {
        let cardY = trayBottom + size * 0.05 + CGFloat(i) * (cardHeight + size * 0.025)
        let cardX = center.x - cardWidth / 2
        let cardRect = CGRect(x: cardX, y: cardY, width: cardWidth, height: cardHeight)
        let cardPath = CGPath(roundedRect: cardRect, cornerWidth: cardCorner, cornerHeight: cardCorner, transform: nil)

        context.addPath(cardPath)
        context.setFillColor(CGColor(red: color.r, green: color.g, blue: color.b, alpha: 0.85))
        context.fillPath()

        // Small icon dot on the left of each card
        let dotX = cardX + size * 0.03
        let dotY = cardY + cardHeight / 2
        let dotR = size * 0.012
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.6))
        context.fillEllipse(in: CGRect(x: dotX - dotR, y: dotY - dotR, width: dotR * 2, height: dotR * 2))

        // Line representing text on the card
        let lineX = cardX + size * 0.06
        let lineW = cardWidth * 0.55 - CGFloat(i) * size * 0.03
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.35))
        context.fill(CGRect(x: lineX, y: dotY - size * 0.004, width: lineW, height: size * 0.008))
    }

    // Down-arrow above the tray (stash action indicator)
    let arrowCenterX = center.x
    let arrowTop = trayBottom + trayHeight + size * 0.06
    let arrowTip = trayBottom + trayHeight + size * 0.02
    let arrowWidth = size * 0.10
    let arrowStemW = size * 0.035
    let arrowStemTop = arrowTop + size * 0.10

    context.setFillColor(CGColor(red: 0.55, green: 0.45, blue: 0.95, alpha: 0.9))

    // Arrow stem
    context.fill(CGRect(x: arrowCenterX - arrowStemW / 2, y: arrowTop,
                         width: arrowStemW, height: arrowStemTop - arrowTop))

    // Arrowhead (triangle pointing down)
    context.move(to: CGPoint(x: arrowCenterX - arrowWidth / 2, y: arrowTop))
    context.addLine(to: CGPoint(x: arrowCenterX + arrowWidth / 2, y: arrowTop))
    context.addLine(to: CGPoint(x: arrowCenterX, y: arrowTip))
    context.closePath()
    context.fillPath()

    image.unlockFocus()
    return image
}

// Generate all required icon sizes
let sizes: [(CGFloat, String)] = [
    (16, "icon_16x16"),
    (32, "icon_16x16@2x"),
    (32, "icon_32x32"),
    (64, "icon_32x32@2x"),
    (128, "icon_128x128"),
    (256, "icon_128x128@2x"),
    (256, "icon_256x256"),
    (512, "icon_256x256@2x"),
    (512, "icon_512x512"),
    (1024, "icon_512x512@2x"),
]

// Create iconset directory
let iconsetPath = "AppIcon.iconset"
let fm = FileManager.default
try? fm.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

for (size, name) in sizes {
    let image = renderIcon(size: size)
    guard let tiffData = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiffData),
          let pngData = bitmap.representation(using: .png, properties: [:]) else {
        print("Failed to generate \(name)")
        continue
    }
    let path = "\(iconsetPath)/\(name).png"
    try! pngData.write(to: URL(fileURLWithPath: path))
    print("Generated \(path) (\(Int(size))x\(Int(size)))")
}

print("\nConverting to .icns...")
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetPath]
try! process.run()
process.waitUntilExit()

if process.terminationStatus == 0 {
    print("Created AppIcon.icns")
} else {
    print("iconutil failed")
}

// Clean up iconset
try? fm.removeItem(atPath: iconsetPath)
