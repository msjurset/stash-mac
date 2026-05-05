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

            // Body with hyperlinks and markdown (bullets, headings, etc.)
            if !message.body.isEmpty {
                MarkdownText(unwrapBodyLinks(message.body), isSelectable: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .environment(\.openURL, OpenURLAction { url in
                        NSWorkspace.shared.open(unwrapURL(url))
                        return .handled
                    })
            }
        }
    }

    /// Rewrites SafeLinks / Google-redirect URLs in the body text in-place so
    /// the rendered markdown shows the real destination. Markdown link bodies
    /// `[label](url)` and bare `https://…` URLs are both handled.
    private func unwrapBodyLinks(_ text: String) -> String {
        let pattern = #"https?://[^\s)<>\]]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return text
        }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        var result = ""
        var lastEnd = 0
        for match in matches {
            let range = match.range
            if range.location > lastEnd {
                result += nsText.substring(with: NSRange(location: lastEnd, length: range.location - lastEnd))
            }
            let urlStr = nsText.substring(with: range)
            if let url = URL(string: urlStr) {
                let unwrapped = unwrapURL(url)
                result += unwrapped.absoluteString
            } else {
                result += urlStr
            }
            lastEnd = range.location + range.length
        }
        if lastEnd < nsText.length {
            result += nsText.substring(from: lastEnd)
        }
        return result
    }
}

// MARK: - Parsing

private struct EmailMessage {
    var headers: [(label: String, value: String)]
    var body: String
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

