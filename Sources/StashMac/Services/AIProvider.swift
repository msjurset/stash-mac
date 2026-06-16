import Foundation

/// Identification result returned by any AI provider. The whole
/// pipeline (right-click → Identify with …, store, UI) talks in this
/// shape, so adding a new provider only requires implementing the
/// `AIProvider` protocol — no callers need to change.
struct AIIdentifyResult: Equatable {
    var title: String?
    var notes: String
    /// Verbatim text extracted from the photo when any is readable
    /// — printed, typed, or handwritten. Gemini and Claude both
    /// produce noticeably better OCR than Vision's
    /// VNRecognizeTextRequest on handwriting and stylized print,
    /// so the default prompt now asks for a TRANSCRIPT: section.
    /// Nil when the photo has no meaningful text (prompt instructs
    /// the model to write "NONE" in that case).
    var transcript: String? = nil
}

/// Plug-in surface for AI image-identification backends.
///
/// To add a new provider (e.g. Claude, OpenAI):
///   1. Create a struct conforming to `AIProvider`.
///   2. Add a case to `AIProviderID` and register it inside
///      `AIProviderRegistry.provider(for:)`.
///   3. That's it — the Settings UI's picker, the prefs store,
///      and the right-click menu pick up the new entry
///      automatically.
protocol AIProvider: Sendable {
    /// Stable, lowercase identifier — used as the persistence prefix
    /// (`ai.<id>.apiKey`, `ai.<id>.prompt`) and as the Picker tag.
    var id: AIProviderID { get }
    /// Human-readable name for the Settings picker and the right-
    /// click "Identify with <Name>" menu item.
    var displayName: String { get }
    /// SF Symbol name for this provider's branding.
    var iconName: String { get }
    /// First few characters of a valid key for this provider — shown
    /// as the placeholder inside the API-key field so the user has
    /// a visual cue they pasted something of the right shape.
    var keyPlaceholder: String { get }
    /// Where the user goes to mint a fresh key.
    var keyURL: URL { get }
    /// Default identify prompt for this provider. Stored in prefs on
    /// first launch and offered as a Reset target.
    var defaultPrompt: String { get }

    /// Network timeout for per-request calls (identify / testKey).
    /// Used to prevent runaway hangs when the backend or network
    /// stalls.
    var timeout: TimeInterval { get }

    /// Cheap key-validity probe — implementations should send the
    /// smallest possible request that exercises authentication.
    func testKey(_ apiKey: String) async throws

    /// Send image bytes + prompt, return parsed title/notes.
    /// Multi-image identify: when more than one image is supplied,
    /// the provider should treat them as the same subject from
    /// different angles. Implementations are responsible for
    /// embedding all of them in the request body.
    func identify(
        apiKey: String,
        media: [AIMedia],
        promptText: String
    ) async throws -> AIIdentifyResult
}

/// Single media payload — used by the multi-item identify API.
/// Plain Data + MIME so both the JPEG-EXIF auto-pull path and the
/// HEIC/PNG/MP4 passthrough work without conversion.
struct AIMedia: Sendable {
    var data: Data
    var mimeType: String
}

/// Concrete provider IDs known to the app. New providers should be
/// added here AND in `AIProviderRegistry.provider(for:)`.
enum AIProviderID: String, CaseIterable, Codable, Hashable, Identifiable {
    case gemini
    case claude
    // case openai   // future — see comment on AIProvider.

    var id: String { rawValue }
}

/// Factory that maps an `AIProviderID` to its concrete
/// implementation. Centralised so the rest of the codebase can stay
/// provider-agnostic — only this function needs editing when new
/// providers come online.
enum AIProviderRegistry {
    static func provider(for id: AIProviderID) -> AIProvider {
        switch id {
        case .gemini:
            return GeminiProvider()
        case .claude:
            return ClaudeProvider()
        }
    }

    /// All registered providers, in picker / menu display order.
    static var all: [AIProvider] {
        AIProviderID.allCases.map { provider(for: $0) }
    }
}

// MARK: - Shared defaults

/// Shared default identify prompt — same shape (TITLE: / NOTES:)
/// across providers so the Mac response parser works on any of
/// them. Mirrors the Android client's default for cross-device
/// consistency. Per-provider overrides live in `AIPrefsStore`.
enum AIPrompts {
    static let defaultIdentify: String = """
Identify the main subject in this photo.

Respond with exactly these three lines, no preamble, no markdown:

TITLE: <common name; include scientific name in parentheses when applicable>
NOTES: <natural prose, three to six sentences. Open by naming the subject in plain language — e.g. "This is the YYYY mushroom (Scientificus nameus), also known as XXXX..." or "This is the eastern bluebird (Sialia sialis), a small thrush native to..." Then cover, where relevant: notable visual characteristics; habitat, range, or season; edibility / toxicity / safety; species commonly confused with it; what specific features visible in this photo helped identify it; and any other interesting facts a curious naturalist would want to know. Be generous with detail — the user will trim what they don't want.>
TRANSCRIPT: <if the photo contains readable text — printed, typed, OR handwritten (including cursive) — transcribe it verbatim here, preserving line breaks where they're meaningful. Cover the entire visible text, not just a sample. If the image contains no meaningful text (e.g. it's a flower, animal, landscape with no signs / labels / writing), write exactly NONE.>

If you can't identify confidently, write TITLE: Unknown and explain your best guess and the reasoning in NOTES.
"""

    /// Prepended to the user's prompt when multiple images travel
    /// in one identify request. Tells the model to treat the photos
    /// as the same subject from different angles instead of N
    /// unrelated items — fixes the "I can't tell which kind of
    /// Wild Rose without the stem / leaves / thorns" case.
    static func multiImageHint(count: Int) -> String {
        "The following \(count) photos are of the same subject from different angles or states. Identify the subject using all photos together.\n\n"
    }

    static let defaultTranscribe: String = """
Transcribe this audio recording exactly.

Respond with exactly these three lines, no preamble, no markdown:

TITLE: <a descriptive title for the recording based on its content, maximum 60 characters>
NOTES: <one or two sentences describing the tone, context, or key takeaway of the audio>
TRANSCRIPT: <the verbatim transcript of every word spoken, preserving natural speech flow and line breaks where they're meaningful>

If the audio is not spoken words (e.g. ambient noise, music, or silence), write TITLE: Audio Capture and describe what you hear in NOTES.
"""

    static let defaultVideoTranscribe: String = """
Identify the subject and transcribe any speech in this video.

Respond with exactly these three lines, no preamble, no markdown:

TITLE: <a descriptive title for the video based on its content, maximum 60 characters>
NOTES: <natural prose, three to six sentences describing the visual subject and context of the video>
TRANSCRIPT: <the verbatim transcript of every word spoken in the video, preserving natural speech flow and line breaks where they're meaningful. If no words are spoken, write NONE.>

If the video is silent and has no clear subject, write TITLE: Video Capture and describe what you see in NOTES.
"""
}

// MARK: - Identify error classification + friendly messaging

/// True when the error is one we expect to clear on its own —
/// model overload (HTTP 503 with "UNAVAILABLE" status), short-
/// window rate limits (HTTP 429 without quota body), and any
/// networking-shaped failure. The identify retry loop in
/// StashStore uses this to decide whether to back off and try
/// again or surface the failure immediately.
///
/// **Quota errors are NOT transient.** Gemini returns HTTP 429
/// for both per-minute rate limits AND daily/free-tier quota
/// exhaustion. We need to distinguish them: quota errors won't
/// clear for hours, so retrying burns more of the user's
/// remaining budget without ever succeeding. The Gemini 429
/// body contains "quota exceeded" / "free_tier_requests" /
/// "current quota" when it's quota; plain rate limits don't.
func isTransientIdentifyError(_ error: Error) -> Bool {
    let msg = error.localizedDescription.lowercased()
    if msg.contains("503") || msg.contains("unavailable") || msg.contains("high demand") {
        return true
    }
    if msg.contains("quota") || msg.contains("free_tier") || msg.contains("billing") {
        // 429-with-quota — permanent for the current quota window.
        // Don't retry.
        return false
    }
    if msg.contains("429") || msg.contains("rate limit") || msg.contains("rate-limit") {
        return true
    }
    if error is URLError { return true }
    return false
}

/// Translate a raw identify error into something the user can
/// actually act on. Suppresses the long JSON body for 503s and
/// distinguishes "wait it out" failures from "your key is wrong."
/// Called when the retry loop has given up.
func friendlyIdentifyErrorMessage(provider: String, error: Error?) -> String {
    guard let error else {
        return "\(provider) identify failed."
    }
    let msg = error.localizedDescription
    let lower = msg.lowercased()
    if lower.contains("503") || lower.contains("unavailable") || lower.contains("high demand") {
        return "\(provider) is currently overloaded. Try again in a few minutes."
    }
    // Quota check MUST come before the 429 check — Gemini returns
    // 429 for both per-minute rate limits and daily / free-tier
    // quota exhaustion, and we need to surface the latter as a
    // hard "stop and upgrade or wait until tomorrow" rather than
    // a "try again shortly" that nudges the user into more
    // futile retries.
    if lower.contains("free_tier") || lower.contains("free tier") {
        return "\(provider) free-tier quota exhausted. Wait for the quota window to reset, or add billing on the API key."
    }
    if lower.contains("quota") || lower.contains("billing") {
        return "\(provider) quota exceeded on this key. Add billing or wait for the quota to reset."
    }
    if lower.contains("429") || lower.contains("rate limit") || lower.contains("rate-limit") {
        return "\(provider) rate limit reached. Try again shortly."
    }
    if lower.contains("401") || lower.contains("403") || lower.contains("api key") || lower.contains("api_key") {
        return "\(provider) rejected the API key. Update it in Settings → AI."
    }
    if error is URLError {
        return "Network error while talking to \(provider). Check your connection and try again."
    }
    // Fall through for truly unknown errors — still strip the
    // verbose JSON body to keep the alert readable.
    let trimmed = msg.count > 200 ? String(msg.prefix(200)) + "…" : msg
    return "\(provider) identify failed: \(trimmed)"
}

// MARK: - Image downscaling (identify-only)

import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Re-encode an image at a smaller size for AI-identify requests.
/// Used **only** in the identify path when multiple photos are
/// bundled into one request — single-image identify always sends
/// the original full-resolution bytes since one image fits cleanly
/// in Gemini's / Claude's request budget. Stored blobs in stash
/// are never touched by this.
///
/// Falls back to the original data when ImageIO can't decode the
/// source (corrupt file, unsupported format) — the worst case is
/// sending the full bytes.
func downscaleForIdentify(
    _ source: AIMedia,
    maxPixelSize: Int = 1024,
    jpegQuality: CGFloat = 0.85
) -> AIMedia {
    guard let cgSource = CGImageSourceCreateWithData(source.data as CFData, nil) else {
        return source
    }
    let opts: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        kCGImageSourceCreateThumbnailWithTransform: true,
    ]
    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(cgSource, 0, opts as CFDictionary)
    else { return source }
    let outData = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(
        outData, UTType.jpeg.identifier as CFString, 1, nil
    ) else { return source }
    let destOpts: [CFString: Any] = [
        kCGImageDestinationLossyCompressionQuality: jpegQuality,
    ]
    CGImageDestinationAddImage(dest, cgImage, destOpts as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { return source }
    return AIMedia(data: outData as Data, mimeType: "image/jpeg")
}

// MARK: - Shared response parsing

/// Robust title/notes extractor shared by every provider. Handles:
///   - explicit "TITLE: ..." / "NOTES: ..." (the format the default
///     prompt asks for)
///   - "Common Name: ..." / "Description: ..." natural fallback
///   - markdown wrappers (`**TITLE:**`)
///
/// If no title marker matches, title returns nil and the entire
/// response goes in notes.
enum AIResponseParser {
    private static let titleMarkers = ["TITLE", "Title", "Common Name", "Common name", "Name", "Subject"]
    private static let notesMarkers = ["NOTES", "Notes", "Description", "Details"]
    private static let summaryMarkers = ["SUMMARY", "Summary"]
    private static let actionItemsMarkers = ["ACTION ITEMS", "Action Items", "ACTION ITEM", "Action Item", "TODO", "Todos", "TASKS", "Tasks"]
    private static let transcriptMarkers = ["TRANSCRIPT", "Transcript", "Text", "OCR"]

    static func parse(_ raw: String) -> AIIdentifyResult {
        let lines = raw.components(separatedBy: "\n")
        var title: String? = nil
        var summary: String? = nil
        var actionItems: String? = nil

        for line in lines {
            if title == nil, let val = extractValue(line, markers: titleMarkers) {
                title = val.cleanInlineMarkers()
            }
        }

        // Capture multi-line blocks
        let transcriptLines = extractMultilineValue(lines, markers: transcriptMarkers)
        let transcript: String? = transcriptLines.map { lines in
            lines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .cleanInlineMarkers()
        }.flatMap { s in
            if s.isEmpty || s.caseInsensitiveCompare("NONE") == .orderedSame { return nil }
            return s
        }
        
        let summaryLines = extractMultilineValue(lines, markers: summaryMarkers)
        summary = summaryLines?.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .cleanInlineMarkers()
            .flatMap { $0.isEmpty ? nil : $0 }
            
        let actionItemsLines = extractMultilineValue(lines, markers: actionItemsMarkers)
        actionItems = actionItemsLines?.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .cleanInlineMarkers()
            .flatMap { s in
                if s.isEmpty || s.caseInsensitiveCompare("NONE") == .orderedSame { return nil }
                return s
            }

        let notesText: String
        if summary != nil || actionItems != nil {
            var parts: [String] = []
            if let s = summary { parts.append(s) }
            if let a = actionItems {
                parts.append("#### ACTION ITEMS\n\(a)")
            }
            notesText = parts.joined(separator: "\n\n")
        } else {
            // Fallback: use lines that aren't markers or transcript
            let transcriptLineSet = Set(transcriptLines ?? [])
            let filtered = lines.filter { line in
                extractValue(line, markers: titleMarkers) == nil &&
                extractValue(line, markers: summaryMarkers) == nil &&
                extractValue(line, markers: actionItemsMarkers) == nil &&
                extractValue(line, markers: transcriptMarkers) == nil &&
                !transcriptLineSet.contains(line)
            }
            let joined = filtered.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            notesText = joined.isEmpty ? raw : joined
        }

        return AIIdentifyResult(
            title: title?.isEmpty == false ? title : nil,
            notes: notesText,
            transcript: transcript
        )
    }

    /// Capture a multi-line block following a marker line, stopping
    /// at the next known marker or EOF. The value on the marker
    /// line itself (after the colon) is the first element. Returns
    /// nil when no marker line is found.
    private static func extractMultilineValue(_ lines: [String], markers: [String]) -> [String]? {
        guard let startIdx = lines.firstIndex(where: { extractValue($0, markers: markers) != nil })
        else { return nil }
        var out: [String] = []
        if let first = extractValue(lines[startIdx], markers: markers), !first.isEmpty {
            out.append(first)
        }
        for i in (startIdx + 1)..<lines.count {
            let line = lines[i]
            if extractValue(line, markers: titleMarkers) != nil { break }
            if extractValue(line, markers: notesMarkers) != nil { break }
            if extractValue(line, markers: summaryMarkers) != nil { break }
            if extractValue(line, markers: actionItemsMarkers) != nil { break }
            if extractValue(line, markers: transcriptMarkers) != nil { break }
            out.append(line)
        }
        return out
    }

    private static func extractValue(_ line: String, markers: [String]) -> String? {
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        let stripped = String(trimmed).trimmingCharacters(in: CharacterSet(charactersIn: "*_# "))
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

extension String {
    /// Strip leading/trailing markdown bold/italic markers off a
    /// single value — the model occasionally wraps the value even
    /// when asked for plain text.
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
