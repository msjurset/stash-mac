import Foundation

/// Minimal REST client for Google's Generative Language API. Mirrors
/// the droid_stash `GeminiClient` shape so the prompts and parser
/// behave identically across devices — a "Identify with Gemini"
/// action on the Mac produces the same Title/Notes split that the
/// phone does.
///
/// Each device holds its own key (stored in UserDefaults); no
/// server round-trip to the phone is needed and Mac use works
/// offline of the user's home LAN.
struct GeminiClient {
    /// What the Mac action ultimately wants: a Title (single line)
    /// and a Notes blob (multi-line prose). The parser handles
    /// "TITLE: ..." + "NOTES: ..." formatted responses, with
    /// fallbacks for "Common Name:" / free-form output.
    struct IdentifyResult: Equatable {
        var title: String?
        var notes: String
    }

    enum GeminiError: LocalizedError {
        case missingKey
        case http(status: Int, body: String)
        case emptyResponse
        case decode(String)

        var errorDescription: String? {
            switch self {
            case .missingKey:
                return "Set a Gemini API key in Settings → Gemini first."
            case .http(let status, let body):
                let snippet = body.count > 200 ? String(body.prefix(200)) + "…" : body
                return "Gemini HTTP \(status): \(snippet)"
            case .emptyResponse:
                return "Gemini returned an empty response."
            case .decode(let msg):
                return "Couldn't decode Gemini response: \(msg)"
            }
        }
    }

    var model: String = "gemini-2.5-flash"
    var urlSession: URLSession = .shared

    /// Cheap key-validity probe — sends a tiny text-only generate.
    func testKey(_ apiKey: String) async throws {
        struct PingBody: Encodable { let contents: [Content] }
        let body = PingBody(
            contents: [Content(parts: [Part(text: "ping", inlineData: nil)])]
        )
        _ = try await postGenerate(apiKey: apiKey, body: body)
    }

    /// Send the image bytes + prompt, return parsed Title / Notes.
    func identify(
        apiKey: String,
        bytes: Data,
        mimeType: String,
        promptText: String
    ) async throws -> IdentifyResult {
        struct IdBody: Encodable { let contents: [Content] }
        let base64 = bytes.base64EncodedString()
        let body = IdBody(
            contents: [
                Content(parts: [
                    Part(text: promptText, inlineData: nil),
                    Part(text: nil, inlineData: InlineData(mimeType: mimeType, data: base64)),
                ])
            ]
        )
        let raw = try await postGenerate(apiKey: apiKey, body: body)
        guard !raw.isEmpty else { throw GeminiError.emptyResponse }
        return Self.parseResponse(raw)
    }

    // MARK: - Wire types

    struct Content: Encodable {
        let parts: [Part]
    }

    struct Part: Encodable {
        let text: String?
        let inlineData: InlineData?
        enum CodingKeys: String, CodingKey {
            case text
            case inlineData = "inline_data"
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            if let text { try c.encode(text, forKey: .text) }
            if let inlineData { try c.encode(inlineData, forKey: .inlineData) }
        }
    }

    struct InlineData: Encodable {
        let mimeType: String
        let data: String
        enum CodingKeys: String, CodingKey {
            case mimeType = "mime_type"
            case data
        }
    }

    private struct GenerateResponse: Decodable {
        let candidates: [Candidate]?
        struct Candidate: Decodable {
            let content: Content?
            struct Content: Decodable {
                let parts: [Part]?
                struct Part: Decodable {
                    let text: String?
                }
            }
        }
    }

    // MARK: - HTTP

    private func postGenerate<T: Encodable>(apiKey: String, body: T) async throws -> String {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GeminiError.missingKey
        }
        let urlString =
            "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)"
        guard let url = URL(string: urlString) else {
            throw GeminiError.decode("bad URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let enc = JSONEncoder()
        req.httpBody = try enc.encode(body)

        let (data, response) = try await urlSession.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        if status < 200 || status >= 300 {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw GeminiError.http(status: status, body: text)
        }
        do {
            let decoded = try JSONDecoder().decode(GenerateResponse.self, from: data)
            let firstText = decoded.candidates?
                .first?
                .content?
                .parts?
                .compactMap { $0.text }
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return firstText ?? ""
        } catch {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw GeminiError.decode("\(error.localizedDescription) — head: \(text.prefix(160))")
        }
    }

    // MARK: - Response parsing

    /// Extract Title + Notes from a Gemini response, robust to the
    /// most common variations the model produces:
    ///   - explicit "TITLE: ..." / "NOTES: ..." (the format the
    ///     default prompt asks for)
    ///   - "Common Name: ..." / "Description: ..." (the strongly-
    ///     trained natural fallback)
    ///   - markdown wrappers (`**TITLE:**`)
    ///
    /// If no title marker matches, title returns nil and the entire
    /// response goes in notes.
    static func parseResponse(_ raw: String) -> IdentifyResult {
        let titleMarkers = ["TITLE", "Title", "Common Name", "Common name", "Name", "Subject"]
        let notesMarkers = ["NOTES", "Notes", "Description", "Details"]

        let lines = raw.components(separatedBy: "\n")

        var title: String? = nil
        var notes: String? = nil

        for line in lines {
            if title == nil, let val = extractValue(line, markers: titleMarkers) {
                title = val.cleanInlineMarkers()
            }
            if notes == nil, let val = extractValue(line, markers: notesMarkers) {
                notes = val.cleanInlineMarkers()
            }
            if title != nil && notes != nil { break }
        }

        let notesText: String
        if let n = notes {
            notesText = n
        } else {
            // Fall back: everything except the matched title line.
            let filtered = lines.filter { line in
                extractValue(line, markers: titleMarkers) == nil
            }
            let joined = filtered.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            notesText = joined.isEmpty ? raw : joined
        }

        return IdentifyResult(
            title: title?.isEmpty == false ? title : nil,
            notes: notesText
        )
    }

    private static func extractValue(_ line: String, markers: [String]) -> String? {
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        let stripped = String(trimmed).trimmingCharacters(in: CharacterSet(charactersIn: "*_ "))
        for m in markers {
            let needle = "\(m):"
            if let r = stripped.range(of: needle, options: [.caseInsensitive, .anchored]) {
                let value = String(stripped[r.upperBound...])
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "*_"))
                    .trimmingCharacters(in: .whitespaces)
                return value
            }
        }
        return nil
    }
}

private extension String {
    /// Strip leading/trailing markdown bold/italic markers off a
    /// single value — Gemini occasionally wraps the value even when
    /// asked for plain text.
    func cleanInlineMarkers() -> String {
        var s = trimmingCharacters(in: .whitespaces)
        for marker in ["**", "__", "*", "_"] {
            if s.hasPrefix(marker) && s.hasSuffix(marker) && s.count > marker.count * 2 {
                let start = s.index(s.startIndex, offsetBy: marker.count)
                let end = s.index(s.endIndex, offsetBy: -marker.count)
                s = String(s[start..<end]).trimmingCharacters(in: .whitespaces)
            }
        }
        return s
    }
}

/// Default identify prompt — mirrors the Android client's default
/// so cross-device output stays consistent. User can override in
/// Settings → Gemini.
enum GeminiDefaultPrompt {
    static let value: String = """
Identify the main subject in this photo.

Respond with exactly these two lines, no preamble, no markdown:

TITLE: <common name; include scientific name in parentheses when applicable>
NOTES: <natural prose, three to six sentences. Open by naming the subject in plain language — e.g. "This is the YYYY mushroom (Scientificus nameus), also known as XXXX..." or "This is the eastern bluebird (Sialia sialis), a small thrush native to..." Then cover, where relevant: notable visual characteristics; habitat, range, or season; edibility / toxicity / safety; species commonly confused with it; what specific features visible in this photo helped identify it; and any other interesting facts a curious naturalist would want to know. Be generous with detail — the user will trim what they don't want.>

If you can't identify confidently, write TITLE: Unknown and explain your best guess and the reasoning in NOTES.
"""
}
