import Foundation

/// Minimal REST client for Google's Generative Language API — the
/// `AIProvider` implementation for `.gemini`. Mirrors the
/// droid_stash Gemini client shape so the prompts and parser
/// behave identically across devices: a "Identify with Gemini"
/// action on the Mac produces the same Title/Notes split that the
/// phone does.
///
/// Each device holds its own key (stored in UserDefaults); no
/// server round-trip to the phone is needed and Mac use works
/// offline of the user's home LAN.
struct GeminiProvider: AIProvider {
    var id: AIProviderID { .gemini }
    var displayName: String { "Google Gemini" }
    var keyPlaceholder: String { "AIza…" }
    var keyURL: URL { URL(string: "https://aistudio.google.com/app/apikey")! }
    var defaultPrompt: String { AIPrompts.defaultIdentify }

    var model: String = "gemini-2.5-flash"
    var urlSession: URLSession = .shared

    enum GeminiError: LocalizedError {
        case missingKey
        case http(status: Int, body: String)
        case emptyResponse
        case decode(String)

        var errorDescription: String? {
            switch self {
            case .missingKey:
                return "Set a Gemini API key in Settings → AI first."
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

    /// Cheap key-validity probe — sends a tiny text-only generate.
    func testKey(_ apiKey: String) async throws {
        struct PingBody: Encodable { let contents: [Content] }
        let body = PingBody(
            contents: [Content(parts: [Part(text: "ping", inlineData: nil)])]
        )
        _ = try await postGenerate(apiKey: apiKey, body: body)
    }

    /// Send the image bytes + prompt, return parsed Title / Notes.
    /// When `images` has more than one entry the prompt is prefixed
    /// with a multi-image hint so the model treats them as one
    /// subject. Single-image requests keep the original prompt.
    func identify(
        apiKey: String,
        images: [AIImage],
        promptText: String
    ) async throws -> AIIdentifyResult {
        guard !images.isEmpty else { throw GeminiError.emptyResponse }
        struct IdBody: Encodable { let contents: [Content] }
        let effectivePrompt = images.count > 1
            ? AIPrompts.multiImageHint(count: images.count) + promptText
            : promptText
        var parts: [Part] = [Part(text: effectivePrompt, inlineData: nil)]
        for img in images {
            parts.append(Part(
                text: nil,
                inlineData: InlineData(
                    mimeType: img.mimeType,
                    data: img.data.base64EncodedString()
                )
            ))
        }
        let body = IdBody(contents: [Content(parts: parts)])
        let raw = try await postGenerate(apiKey: apiKey, body: body)
        guard !raw.isEmpty else { throw GeminiError.emptyResponse }
        return AIResponseParser.parse(raw)
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
}
