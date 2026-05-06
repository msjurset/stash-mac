import SwiftUI

/// Builds an `AttributedString` that highlights `#tag` substrings with a
/// monospaced font, accent foreground, and a subtle tinted background —
/// so descriptions like "Tag YouTube URLs as #video and #watch-later"
/// scan cleanly and the tags pop visually.
///
/// Pattern: `#` followed by one or more word characters or hyphens.
/// Matches "#video", "#watch-later", "#read-later". A bare "#" or "# foo"
/// won't match (no word char follows). False positives like "PR #123"
/// will get styled — acceptable; the highlight just makes them more
/// visible.
func taggedAttributedString(_ raw: String, color: Color = .blue) -> AttributedString {
    let pattern = #"#[\w-]+"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
        return AttributedString(raw)
    }
    let ns = raw as NSString
    let matches = regex.matches(in: raw, range: NSRange(location: 0, length: ns.length))

    var result = AttributedString()
    var lastEnd = 0
    for match in matches {
        let range = match.range
        if range.location > lastEnd {
            let plain = ns.substring(with: NSRange(location: lastEnd, length: range.location - lastEnd))
            result += AttributedString(plain)
        }
        let tag = ns.substring(with: range)
        var tagPart = AttributedString(tag)
        tagPart.foregroundColor = color
        tagPart.backgroundColor = color.opacity(0.12)
        tagPart.font = .system(.callout, design: .monospaced).weight(.medium)
        result += tagPart
        lastEnd = range.location + range.length
    }
    if lastEnd < ns.length {
        result += AttributedString(ns.substring(from: lastEnd))
    }
    return result
}
