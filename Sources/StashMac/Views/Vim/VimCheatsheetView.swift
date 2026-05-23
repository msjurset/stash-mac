import SwiftUI

/// Vim command reference popover. Ported verbatim from jrnlbar's
/// VimCheatsheetView. Shown when the user clicks the "?" button next
/// to the active vim badge — covers every command VimEngine supports
/// so the user can discover capabilities without leaving the app.
struct VimCheatsheetView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                section("Movement") {
                    row("h j k l", "left / down / up / right (visual lines)")
                    row("gj / gk", "down / up by LOGICAL line (true \\n)")
                    row("w / b", "start of next / previous word")
                    row("e / ge", "end of current / previous word")
                    row("W B E", "WORD variants (whitespace-only separators)")
                    row("0 / ^", "line start / first non-blank")
                    row("$", "line end")
                    row("{ / }", "previous / next paragraph (blank line)")
                    row("%", "matching ( ) [ ] { } bracket")
                    row("gg / G", "top / bottom of buffer")
                    row("NG / Ngg / :N", "jump to absolute line N")
                    row("Ctrl-d / Ctrl-u", "half-page down / up")
                    row("Ctrl-f / Ctrl-b", "full-page down / up")
                    row("H / M / L", "top / middle / bottom visible line")
                    row("zz / zt / zb", "scroll cursor line to center / top / bottom")
                    row("arrows", "same as h j k l")
                    row("Nx", "count prefix repeats: 5w, 3l, 2dd…")
                }
                section("Insert mode") {
                    row("i / a", "insert before / after cursor")
                    row("I / A", "insert at line start / line end")
                    row("o / O", "open new line below / above")
                    row("Esc", "back to normal mode")
                }
                section("Delete") {
                    row("x / X", "delete forward / backward (bounded by line)")
                    row("dd", "delete line (Ndd for N lines)")
                    row("dw / de", "delete word / through end of word")
                    row("db / d0 / d$", "delete back / to line start / end")
                    row("D", "delete to end of line")
                    row("J", "join next line with a space (NJ for N joins)")
                }
                section("Change") {
                    row("cc", "empty line, enter insert")
                    row("cw / ce", "change word (delete + insert)")
                    row("c0 / c$ / c^", "change to line start / end / first non-blank")
                    row("C", "change to end of line")
                    row("s", "substitute char (delete + insert)")
                }
                section("Replace") {
                    row("r<x>", "replace one character with x")
                    row("Nr<x>", "replace N characters with x")
                    row("R", "overstrike mode — overwrite until Esc")
                }
                section("Visual selection") {
                    row("v / V", "char-wise / line-wise visual mode")
                    row("gv", "re-enter last visual selection")
                    row("Esc", "exit visual mode")
                    row("d / x", "delete selection")
                    row("y", "yank selection")
                    row("c", "change selection (delete + insert)")
                    row("~ / U / u", "toggle / upper / lower case of selection")
                }
                section("Search") {
                    row("/<term>", "search forward (Enter to commit)")
                    row("?<term>", "search backward")
                    row("* / #", "search word under cursor forward / backward")
                    row("n / N", "repeat in same / opposite direction")
                    row("Esc", "cancel search input")
                }
                section("Marks") {
                    row("m<a-z>", "set mark at current position")
                    row("'<a-z>", "jump to line start of mark")
                    row("`<a-z>", "jump to exact mark position")
                }
                section("Find in line") {
                    row("f<x>", "next occurrence of x on this line")
                    row("F<x>", "previous occurrence of x")
                    row("t<x>", "next x, land just before it")
                    row("T<x>", "previous x, land just after it")
                    row("; / ,", "repeat last find / reverse")
                }
                section("Repeat") {
                    row(".", "repeat last text-changing command (incl. inserted text)")
                }
                section("Indent / outdent") {
                    row(">> / <<", "indent / outdent current line by 2 spaces")
                    row("N>> / N<<", "operate on N lines")
                    row(">{motion} / <{motion}", "indent / outdent over motion")
                    row("Visual > / <", "indent / outdent selected lines")
                }
                section("Text objects (with d / c / y / gU / gu / g~)") {
                    row("iw / aw", "inner / around word")
                    row("iW / aW", "inner / around WORD")
                    row("i\" / a\"", "inside / around \"…\"")
                    row("i' / a'", "inside / around '…'")
                    row("i` / a`", "inside / around `…`")
                    row("i( / a(", "inside / around ( … )  (and i)/a))")
                    row("i[ / a[", "inside / around [ … ]  (and i]/a])")
                    row("i{ / a{", "inside / around { … }  (and i}/a})")
                }
                section("Case operators") {
                    row("gU{motion}", "uppercase over motion (gUw, gUiw, gU$…)")
                    row("gu{motion}", "lowercase over motion")
                    row("g~{motion}", "toggle case over motion")
                    row("gUU / guu / g~~", "operate on whole line")
                    row("~", "toggle case of character under cursor")
                }
                section("Yank & paste") {
                    row("yy / Y", "yank current line (Nyy for N lines)")
                    row("yw / ye", "yank word")
                    row("p / P", "paste after / before")
                    row("Np", "paste N times")
                }
                section("Undo / redo") {
                    row("u", "undo")
                    row("Ctrl-r", "redo")
                }
                section("Command line") {
                    row(":q  /  :vim", "exit vim mode")
                    row(":w", "save / commit current edit (stay in vim)")
                    row(":wq", "save + exit vim")
                    row("Esc", "cancel command line")
                }
                section("Exit vim") {
                    row("Click VIM pill", "exit and return to normal editing")
                    row("Type /vim again", "toggle off (insert mode only)")
                }
            }
            .padding(14)
        }
        .frame(width: 340, height: 420)
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption2)
                .fontWeight(.bold)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func row(_ cmd: String, _ desc: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(cmd)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.primary)
                .frame(width: 110, alignment: .leading)
            Text(desc)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
