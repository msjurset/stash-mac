import Foundation

/// REST client for Anthropic's Messages API — the `AIProvider`
/// implementation for `.claude`. Uses the same `AIResponseParser`
/// as the Gemini provider so the same TITLE: / NOTES: prompt
/// produces the same shape of result regardless of which backend
/// the user picks.
struct ClaudeProvider: AIProvider {
    var id: AIProviderID { .claude }
    var displayName: String { "Anthropic Claude" }
    var keyPlaceholder: String { "sk-ant-…" }
    var keyURL: URL { URL(string: "https://console.anthropic.com/settings/keys")! }
    var defaultPrompt: String { AIPrompts.defaultIdentify }

    /// Sonnet-class model — vision-capable, well-suited to the
    /// "identify subject" prompt. Cheaper than Opus, more capable
    /// than Haiku for the multi-sentence prose response.
    var model: String = "claude-sonnet-4-6"
    /// Anthropic API version header. Pinned — bumping this without
    /// updating wire types can break the response shape.
    var apiVersion: String = "2023-06-01"
    /// Plenty of headroom for the 3-6 sentence response the default
    /// prompt asks for.
    var maxTokens: Int = 1024
    var urlSession: URLSession = .shared

    enum ClaudeError: LocalizedError {
        case missingKey
        case http(status: Int, body: String)
        case emptyResponse
        case decode(String)

        var errorDescription: String? {
            switch self {
            case .missingKey:
                return "Set a Claude API key in Settings → AI first."
            case .http(let status, let body):
                let snippet = body.count > 200 ? String(body.prefix(200)) + "…" : body
                return "Claude HTTP \(status): \(snippet)"
            case .emptyResponse:
                return "Claude returned an empty response."
            case .decode(let msg):
                return "Couldn't decode Claude response: \(msg)"
            }
        }
    }

    /// Cheap key-validity probe — sends a tiny text-only message.
    func testKey(_ apiKey: String) async throws {
        let body = MessagesBody(
            model: model,
            max_tokens: 16,
            messages: [
                Message(role: "user", content: [.text("ping")])
            ]
        )
        _ = try await postMessages(apiKey: apiKey, body: body)
    }

    /// Send the image bytes + prompt, return parsed Title / Notes.
    /// Multi-image support mirrors the Gemini side: when more than
    /// one image is sent, prefix the prompt with a hint so Claude
    /// treats them as the same subject from different angles.
    func identify(
        apiKey: String,
        images: [AIImage],
        promptText: String
    ) async throws -> AIIdentifyResult {
        guard !images.isEmpty else { throw ClaudeError.emptyResponse }
        let effectivePrompt = images.count > 1
            ? AIPrompts.multiImageHint(count: images.count) + promptText
            : promptText
        // Anthropic recommends image-first then text — images get
        // primed before the instruction lands.
        var content: [ContentBlock] = []
        for img in images {
            content.append(.image(
                mediaType: img.mimeType,
                data: img.data.base64EncodedString()
            ))
        }
        content.append(.text(effectivePrompt))
        let body = MessagesBody(
            model: model,
            max_tokens: maxTokens,
            messages: [Message(role: "user", content: content)]
        )
        let raw = try await postMessages(apiKey: apiKey, body: body)
        guard !raw.isEmpty else { throw ClaudeError.emptyResponse }
        return AIResponseParser.parse(raw)
    }

    // MARK: - Wire types

    private struct MessagesBody: Encodable {
        let model: String
        let max_tokens: Int
        let messages: [Message]
    }

    private struct Message: Encodable {
        let role: String
        let content: [ContentBlock]
    }

    /// Content block — Anthropic accepts a polymorphic array with
    /// `type: text` or `type: image`. Encoded manually so the JSON
    /// matches the wire format exactly.
    private enum ContentBlock: Encodable {
        case text(String)
        case image(mediaType: String, data: String)

        enum CodingKeys: String, CodingKey {
            case type, text, source
        }
        enum SourceKeys: String, CodingKey {
            case type, media_type, data
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let s):
                try c.encode("text", forKey: .type)
                try c.encode(s, forKey: .text)
            case .image(let mediaType, let data):
                try c.encode("image", forKey: .type)
                var src = c.nestedContainer(keyedBy: SourceKeys.self, forKey: .source)
                try src.encode("base64", forKey: .type)
                try src.encode(mediaType, forKey: .media_type)
                try src.encode(data, forKey: .data)
            }
        }
    }

    private struct MessagesResponse: Decodable {
        let content: [ResponseBlock]?
        struct ResponseBlock: Decodable {
            let type: String
            let text: String?
        }
    }

    // MARK: - HTTP

    private func postMessages<T: Encodable>(apiKey: String, body: T) async throws -> String {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ClaudeError.missingKey
        }
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw ClaudeError.decode("bad URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        let enc = JSONEncoder()
        req.httpBody = try enc.encode(body)

        let (data, response) = try await urlSession.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        if status < 200 || status >= 300 {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw ClaudeError.http(status: status, body: text)
        }
        do {
            let decoded = try JSONDecoder().decode(MessagesResponse.self, from: data)
            let firstText = decoded.content?
                .compactMap { $0.type == "text" ? $0.text : nil }
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return firstText ?? ""
        } catch {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw ClaudeError.decode("\(error.localizedDescription) — head: \(text.prefix(160))")
        }
    }
}
