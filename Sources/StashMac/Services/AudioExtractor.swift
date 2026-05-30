import AVFoundation
import Foundation

enum AudioExtractor {
    enum ExtractionError: LocalizedError {
        case exportFailed(String)
        case unsupportedFormat

        var errorDescription: String? {
            switch self {
            case .exportFailed(let msg): return "Export failed: \(msg)"
            case .unsupportedFormat: return "The video format is not supported for audio extraction."
            }
        }
    }

    /// Extracts the audio track from a video file using AVFoundation and returns the M4A bytes.
    /// This runs locally to support "Lite Mode" transcription, avoiding the high cost
    /// of sending full video files to the AI provider.
    static func extractAudio(from videoURL: URL) async throws -> Data {
        let asset = AVURLAsset(url: videoURL)
        
        let tempDir = FileManager.default.temporaryDirectory
        let outURL = tempDir.appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")

        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw ExtractionError.unsupportedFormat
        }

        exportSession.outputURL = outURL
        exportSession.outputFileType = .m4a

        if #available(macOS 15.0, *) {
            try await exportSession.export(to: outURL, as: .m4a)
            let data = try Data(contentsOf: outURL)
            try? FileManager.default.removeItem(at: outURL)
            return data
        } else {
            await exportSession.export()

            switch exportSession.status {
            case .completed:
                let data = try Data(contentsOf: outURL)
                try? FileManager.default.removeItem(at: outURL)
                return data
            case .failed:
                throw ExtractionError.exportFailed(exportSession.error?.localizedDescription ?? "Unknown AVFoundation error")
            case .cancelled:
                throw ExtractionError.exportFailed("Export cancelled")
            default:
                throw ExtractionError.exportFailed("Unexpected export status: \(exportSession.status.rawValue)")
            }
        }
    }
}
