import SwiftUI

/// Context this guide is being shown in — drives the footer
/// section. Rule conditions need the named-capture / template
/// reference; the global search panel needs the negation prefix
/// reference (the `--regex !` form). The columns above are the
/// same in both contexts.
enum RegexGuideContext {
    case rulesEngine
    case searchPanel
}

/// Compact 3-column reference for the RE2 regex flavor used by gostash's
/// `url_regex` / `content_regex` match conditions and the global search
/// panel's regex toggle. Shown as a popover anchored to whichever
/// affordance owns the regex input.
///
/// Sized for ~520×360 — fits the most-used patterns without scrolling.
/// If users want more, this is the place to add a "More…" link to a
/// docs page or expand into a sheet.
struct RegexGuideView: View {
    var context: RegexGuideContext = .rulesEngine

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

            footer
        }
        .padding(14)
        .frame(width: 520)
    }

    @ViewBuilder
    private var footer: some View {
        switch context {
        case .rulesEngine:
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
        case .searchPanel:
            VStack(alignment: .leading, spacing: 4) {
                Text("Negation")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text("Prefix the pattern with ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                + Text("!")
                    .font(.caption.monospaced())
                    .foregroundStyle(.primary)
                + Text(" to invert the match — items whose title, notes, URL, or extracted text do NOT match the pattern.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("e.g. ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                + Text("!^https://")
                    .font(.caption.monospaced())
                + Text(" → items whose URL doesn't start with https.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Tag filters are disabled in regex mode — `tag:` may be a literal in your pattern.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
        }
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
