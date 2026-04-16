import SwiftUI

/// Renders extracted email text with formatted headers, thread separation,
/// and clickable hyperlinks.
struct EmailContentView: View {
    let text: String

    /// Parse the email into a sequence of thread messages.
    /// Each message has optional headers and a body.
    private var messages: [EmailMessage] {
        parseThread(normalizeHeaders(text))
    }

    var body: some View {
        DetailSection(title: "Email") {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(messages.enumerated()), id: \.offset) { idx, message in
                    if idx > 0 {
                        Divider()
                            .padding(.vertical, 8)
                    }
                    emailMessageView(message, isTopLevel: idx == 0)
                }
            }
        }
    }

    @ViewBuilder
    private func emailMessageView(_ message: EmailMessage, isTopLevel: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Headers
            if !message.headers.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(message.headers.enumerated()), id: \.offset) { _, header in
                        HStack(alignment: .top, spacing: 6) {
                            Text(header.label)
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)
                                .frame(width: 55, alignment: .trailing)
                            Text(header.value)
                                .font(.caption)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(isTopLevel ? AnyShapeStyle(Color.accentColor.opacity(0.08)) : AnyShapeStyle(.quaternary.opacity(0.5)))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            // Body with hyperlinks
            if !message.body.isEmpty {
                bodyView(message.body)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    @ViewBuilder
    private func bodyView(_ text: String) -> some View {
        Text(attributedBody(text))
            .font(.body)
            .lineSpacing(4)
            .textSelection(.enabled)
            .environment(\.openURL, OpenURLAction { url in
                NSWorkspace.shared.open(url)
                return .handled
            })
    }

    private func attributedBody(_ text: String) -> AttributedString {
        var result = AttributedString()
        for part in parseBodyParts(text) {
            switch part {
            case .text(let str):
                result += AttributedString(str)
            case .link(let label, let url):
                var chunk = AttributedString(label)
                chunk.link = url
                chunk.foregroundColor = .accentColor
                result += chunk
            }
        }
        return result
    }
}

// MARK: - Parsing

private struct EmailMessage {
    var headers: [(label: String, value: String)]
    var body: String
}

private enum BodyPart {
    case text(String)
    case link(label: String, url: URL)
}

/// Ensure known header keywords always start on their own line. Older CLI
/// versions (or non-compliant senders) occasionally emit headers concatenated
/// inline (e.g. `...EngagementFrom: Stephen...`); this splits them back out
/// so the line-based parser can find them.
private func normalizeHeaders(_ text: String) -> String {
    let pattern = #"(?<=[^\n])(From|To|Cc|Bcc|Date|Sent|Subject|Reply-To): "#
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
        return text
    }
    let nsText = text as NSString
    let range = NSRange(location: 0, length: nsText.length)
    return regex.stringByReplacingMatches(
        in: text,
        range: range,
        withTemplate: "\n$1: "
    )
}

/// Parse the full email text into threaded messages by detecting inline
/// header blocks (From:/Date:/To:/Subject: sequences).
private func parseThread(_ text: String) -> [EmailMessage] {
    let lines = text.components(separatedBy: "\n")
    var messages: [EmailMessage] = []
    var currentHeaders: [(String, String)] = []
    var currentBody: [String] = []
    var inHeaders = true
    var headerLineCount = 0

    for line in lines {
        // Check if this line starts a header block
        let isHeaderLine = ["From: ", "To: ", "Date: ", "Subject: "].contains(where: { line.hasPrefix($0) })

        if isHeaderLine && (inHeaders || isStartOfNewHeaderBlock(line, previous: currentBody)) {
            if !inHeaders && !currentBody.isEmpty {
                // We hit a new header block — save the current message
                messages.append(EmailMessage(
                    headers: currentHeaders,
                    body: currentBody.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                ))
                currentHeaders = []
                currentBody = []
            }
            inHeaders = true
            headerLineCount += 1
            let prefix = ["From: ", "To: ", "Date: ", "Subject: "].first(where: { line.hasPrefix($0) })!
            currentHeaders.append((String(prefix.dropLast(2)), String(line.dropFirst(prefix.count))))
        } else if inHeaders && line.isEmpty {
            // Blank line after headers — switch to body
            inHeaders = false
            headerLineCount = 0
        } else {
            inHeaders = false
            headerLineCount = 0
            currentBody.append(line)
        }
    }

    // Save the last message
    messages.append(EmailMessage(
        headers: currentHeaders,
        body: currentBody.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    ))

    return messages
}

/// Detect if a "From:" line starts a new thread message (vs. being body text).
/// Heuristic: check if the next few lines also look like headers.
private func isStartOfNewHeaderBlock(_ line: String, previous: [String]) -> Bool {
    // Must start with "From: " and the previous body should have some content
    guard line.hasPrefix("From: ") else { return false }
    // If we have body content before this, it's likely a thread separator
    let trimmed = previous.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    return !trimmed.isEmpty
}

/// Parse body text into segments of plain text and clickable hyperlinks.
/// Matches (in priority order): markdown links `[label](url)`, URLs in
/// parentheses `(https://...)`, angle brackets `<https://...>`, or bare
/// `https://...`. Surrounding text is emitted as-is.
private func parseBodyParts(_ text: String) -> [BodyPart] {
    let urlPattern = try! NSRegularExpression(
        pattern: #"\[([^\]]+)\]\((https?://[^\s)]+)\)|\((https?://[^\s)]+)\)|<(https?://[^\s>]+)>|(https?://[^\s)<>]+)"#
    )

    let nsText = text as NSString
    let fullRange = NSRange(location: 0, length: nsText.length)
    var parts: [BodyPart] = []
    var lastEnd = 0

    for match in urlPattern.matches(in: text, range: fullRange) {
        let matchRange = match.range

        if matchRange.location > lastEnd {
            let before = nsText.substring(with: NSRange(location: lastEnd, length: matchRange.location - lastEnd))
            parts.append(.text(before))
        }

        // Group 1+2: markdown link [label](url) — use label as display text
        if match.range(at: 1).location != NSNotFound,
           match.range(at: 2).location != NSNotFound {
            let label = nsText.substring(with: match.range(at: 1))
            let urlStr = nsText.substring(with: match.range(at: 2))
            if let url = URL(string: urlStr) {
                parts.append(.link(label: label, url: url))
            } else {
                parts.append(.text(nsText.substring(with: matchRange)))
            }
        } else {
            let urlStr: String
            if match.range(at: 3).location != NSNotFound {
                urlStr = nsText.substring(with: match.range(at: 3))
            } else if match.range(at: 4).location != NSNotFound {
                urlStr = nsText.substring(with: match.range(at: 4))
            } else {
                urlStr = nsText.substring(with: match.range(at: 5))
            }

            if let url = URL(string: urlStr) {
                parts.append(.link(label: linkLabel(for: url), url: url))
            } else {
                parts.append(.text(nsText.substring(with: matchRange)))
            }
        }

        lastEnd = matchRange.location + matchRange.length
    }

    if lastEnd < nsText.length {
        parts.append(.text(nsText.substring(from: lastEnd)))
    }

    return parts.isEmpty ? [.text(text)] : parts
}

/// Unwrap SafeLinks/redirect URLs to get the real destination.
private func unwrapURL(_ url: URL) -> URL {
    // Outlook SafeLinks: https://nam10.safelinks.protection.outlook.com/?url=https%3A%2F%2F...
    if let host = url.host, host.contains("safelinks.protection.outlook.com"),
       let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
       let realURLStr = components.queryItems?.first(where: { $0.name == "url" })?.value,
       let realURL = URL(string: realURLStr) {
        return realURL
    }
    // Google redirect: https://www.google.com/url?q=https%3A%2F%2F...
    if let host = url.host, host.contains("google.com"), url.path == "/url",
       let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
       let realURLStr = components.queryItems?.first(where: { $0.name == "q" })?.value,
       let realURL = URL(string: realURLStr) {
        return realURL
    }
    return url
}

/// Generate a short readable label for a URL.
private func linkLabel(for url: URL) -> String {
    let resolved = unwrapURL(url)
    // Use the last meaningful path component if available
    let pathParts = resolved.path.split(separator: "/").filter { $0 != "index.html" }
    if let last = pathParts.last, !last.isEmpty {
        return String(last)
    }
    return resolved.host ?? resolved.absoluteString
}
