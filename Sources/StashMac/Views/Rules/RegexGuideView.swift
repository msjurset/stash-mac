import SwiftUI

/// Compact 3-column reference for the RE2 regex flavor used by gostash's
/// `url_regex` and `content_regex` match conditions. Shown as a popover
/// anchored to the condition's value field while it's focused; collapses
/// when focus leaves.
///
/// Sized for ~480×360 — fits the most-used patterns without scrolling.
/// If users want more, this is the place to add a "More…" link to a
/// docs page or expand into a sheet.
struct RegexGuideView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Regex reference")
                    .font(.headline)
                Text("RE2 syntax")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
            }

            HStack(alignment: .top, spacing: 16) {
                column(title: "Anchors & quantifiers", entries: [
                    ("^",       "start of line"),
                    ("$",       "end of line"),
                    ("\\b",     "word boundary"),
                    ("*",       "0 or more"),
                    ("+",       "1 or more"),
                    ("?",       "0 or 1 (also: lazy)"),
                    ("{n}",     "exactly n"),
                    ("{n,m}",   "n to m"),
                    ("|",       "alternation"),
                ])

                column(title: "Character classes", entries: [
                    (".",        "any (not newline)"),
                    ("\\d",      "digit"),
                    ("\\w",      "word char"),
                    ("\\s",      "whitespace"),
                    ("\\D \\W \\S","negated"),
                    ("[abc]",    "any of a/b/c"),
                    ("[^abc]",   "none of a/b/c"),
                    ("[a-z]",    "range"),
                ])

                column(title: "Groups & flags", entries: [
                    ("(...)",          "capture group"),
                    ("(?:...)",        "non-capturing"),
                    ("(?P<name>...)",  "named capture"),
                    ("(?i)",           "case-insensitive"),
                    ("(?m)",           "multiline ^/$"),
                    ("(?s)",           ". matches newline"),
                ])
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Templates")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text("Named captures land in templates as ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                + Text("{{.Captures.name}}")
                    .font(.caption.monospaced())
                    .foregroundStyle(.primary)
                Text("e.g. ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                + Text(#"content_regex: "Total:\s*(?P<amount>\$[0-9.]+)""#)
                    .font(.caption.monospaced())
                + Text(" → ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                + Text(#"set_title: "Invoice {{.Captures.amount}}""#)
                    .font(.caption.monospaced())
            }
        }
        .padding(14)
        .frame(width: 520)
    }

    @ViewBuilder
    private func column(title: String, entries: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.bottom, 2)
            ForEach(entries.indices, id: \.self) { i in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(entries[i].0)
                        .font(.caption.monospaced())
                        .foregroundStyle(.primary)
                        .frame(minWidth: 60, alignment: .leading)
                    Text(entries[i].1)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
