import AppKit
import AVFoundation
import SwiftUI

/// Generates a waveform image for an audio file.
@MainActor
enum WaveformGenerator {
    
    /// Generate a 512x512 waveform image.
    static func generateWaveform(at url: URL) async -> NSImage? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first else {
            return nil
        }
        
        let samples = await extractSamples(from: asset, track: track, count: 128, fullDuration: false)
        guard !samples.isEmpty else { return nil }
        
        let view = WaveformThumbnailView(samples: samples)
        let renderer = ImageRenderer(content: view)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2.0
        return renderer.nsImage
    }
    
    static func extractSamples(
        from asset: AVAsset, 
        track: AVAssetTrack, 
        count: Int, 
        fullDuration: Bool = false,
        timeRange: CMTimeRange? = nil
    ) async -> [Float] {
        print("[WAVE] Starting extraction (\(count) points, full=\(fullDuration), range=\(timeRange != nil))")
        guard let reader = try? AVAssetReader(asset: asset) else { 
            print("[WAVE] Error: Failed to create AVAssetReader")
            return [] 
        }
        
        let assetDuration = (try? await asset.load(.duration)) ?? .indefinite
        
        if let targetedRange = timeRange {
            reader.timeRange = targetedRange
        } else if !fullDuration {
            let maxDuration = CMTime(seconds: 30, preferredTimescale: 600)
            reader.timeRange = CMTimeRange(
                start: .zero,
                duration: assetDuration.seconds > 30 ? maxDuration : assetDuration
            )
        }
        
        let effectiveDuration = timeRange?.duration.seconds ?? (fullDuration ? assetDuration.seconds : min(30, assetDuration.seconds))

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        reader.add(output)
        
        guard reader.startReading() else { 
            print("[WAVE] Error: reader.startReading() returned false")
            return [] 
        }
        
        let estimatedTotalSamples = Int(max(1.0, effectiveDuration) * 44100)
        let samplesPerPoint = max(1, estimatedTotalSamples / count)
        
        var points: [Float] = []
        points.reserveCapacity(count)
        
        var currentChunkMax: Int16 = 0
        var samplesInCurrentChunk = 0
        
        while reader.status == .reading {
            var shouldBreak = false
            autoreleasepool {
                guard let buffer = output.copyNextSampleBuffer() else {
                    shouldBreak = true
                    return
                }
                guard let blockBuffer = CMSampleBufferGetDataBuffer(buffer) else {
                    shouldBreak = true
                    return
                }
                
                let length = CMBlockBufferGetDataLength(blockBuffer)
                let sampleCount = length / 2
                
                var localBuffer = [Int16](repeating: 0, count: sampleCount)
                localBuffer.withUnsafeMutableBufferPointer { ptr in
                    CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: ptr.baseAddress!)
                    
                    for i in 0..<sampleCount {
                        let sample = abs(ptr[i])
                        if sample > currentChunkMax { currentChunkMax = sample }
                        samplesInCurrentChunk += 1
                        
                        if samplesInCurrentChunk >= samplesPerPoint {
                            points.append(Float(currentChunkMax) / Float(Int16.max))
                            currentChunkMax = 0
                            samplesInCurrentChunk = 0
                            if points.count >= count { break }
                        }
                    }
                }
                if points.count >= count { shouldBreak = true }
            }
            if shouldBreak { break }
        }
        
        if reader.status == .failed {
            print("[WAVE] Error: Reader failed with status \(reader.status)")
            reader.cancelReading()
            return []
        }
        
        if points.isEmpty { return [] }
        
        // Normalize
        let globalPeak = points.max() ?? 1.0
        if globalPeak > 0 && globalPeak < 1.0 {
            points = points.map { $0 / globalPeak }
        }
        
        print("[WAVE] Extraction complete. Got \(points.count) points.")
        return points
    }
}

private struct WaveformThumbnailView: View {
    let samples: [Float]
    
    var body: some View {
        ZStack {
            // Background matches the standard file-type palette (like M4A)
            LinearGradient(
                colors: [
                    Color(red: 0.29, green: 0.33, blue: 0.42),
                    Color(red: 0.17, green: 0.19, blue: 0.25)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            
            Canvas { context, size in
                let width = size.width
                let height = size.height
                let midY = height / 2
                let spacing = width / CGFloat(samples.count)
                
                for (i, sample) in samples.enumerated() {
                    let x = CGFloat(i) * spacing + (spacing / 2)
                    // Scale to 60% of height max so it breathes
                    let barHeight = CGFloat(sample) * height * 0.6 
                    let rect = CGRect(
                        x: x - (spacing * 0.35), // slightly thinner bars
                        y: midY - (barHeight / 2),
                        width: spacing * 0.7,
                        height: max(3, barHeight) // min height of 3 so silence is a visible line
                    )
                    context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(.white.opacity(0.85)))
                }
            }
            .padding(32)
            
            // Overlay a small mic icon to indicate it's audio
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Image(systemName: "mic.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(.white.opacity(0.25))
                        .padding(24)
                }
            }
        }
        .frame(width: 512, height: 512)
    }
}
