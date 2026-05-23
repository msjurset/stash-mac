import Foundation
import Vision
import AppKit

/// On-device OCR for image imports. Uses VNRecognizeTextRequest's
/// "accurate" recognition level — slower than `.fast` but the
/// quality difference matters for book pages / handwriting where
/// `.fast` mis-reads enough characters that the user would have to
/// hand-edit anyway. Still completes well under a second for a
/// typical phone photo.
///
/// Caller decides what to do with short / nonsense results via
/// `looksSubstantial(_:)` — by default we apply a 50-character
/// floor so a photo of a flower with a "EXIT" sign in the
/// background doesn't populate `extracted_text`.
enum TextRecognizer {

    /// Recognize text in the image at `fileURL`. Returns the
    /// recognized lines joined with newlines, or nil if nothing
    /// usable was found or the recognizer failed.
    static func recognize(fileURL: URL) async -> String? {
        guard let cgImage = loadCGImage(at: fileURL) else { return nil }
        return await recognize(cgImage: cgImage)
    }

    /// Recognize text in a CGImage. Pulled out so callers that
    /// already have one (e.g. ThumbnailCache) can skip the disk
    /// hop.
    static func recognize(cgImage: CGImage) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            let request = VNRecognizeTextRequest { request, _ in
                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    cont.resume(returning: nil)
                    return
                }
                let lines = observations.compactMap { obs -> String? in
                    obs.topCandidates(1).first?.string
                }
                let joined = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                cont.resume(returning: joined.isEmpty ? nil : joined)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                cont.resume(returning: nil)
            }
        }
    }

    /// Whether the OCR result clears the substantial-text floor.
    /// Mirrors the Android `TextRecognizer.looksSubstantial`
    /// heuristic so both clients suppress the same casual-photo
    /// noise (single words on signs, watermarks, etc.).
    static func looksSubstantial(_ text: String?) -> Bool {
        guard let text else { return false }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 50
    }

    /// Decode a CGImage from the file at `fileURL`. Honors EXIF
    /// orientation so the OCR engine sees the image upright — saves
    /// the user from rotated-text mis-reads.
    private static func loadCGImage(at fileURL: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            // Large enough to keep small print legible. OCR doesn't
            // benefit from sending the full multi-megapixel pixels —
            // 2048 on the long edge is plenty for a 12MP phone photo
            // and saves CPU.
            kCGImageSourceThumbnailMaxPixelSize: 2048,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
    }
}
