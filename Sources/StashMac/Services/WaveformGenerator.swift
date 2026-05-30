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
        
        let samples = await extractSamples(from: asset, track: track, count: 128)
        guard !samples.isEmpty else { return nil }
        
        let view = WaveformThumbnailView(samples: samples)
        let renderer = ImageRenderer(content: view)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2.0
        return renderer.nsImage
    }
    
    private static func extractSamples(from asset: AVAsset, track: AVAssetTrack, count: Int) async -> [Float] {
        guard let reader = try? AVAssetReader(asset: asset) else { return [] }
        
        // Limit sampling to the first 30 seconds to keep it fast even for hours-long audio
        let maxDuration = CMTime(seconds: 30, preferredTimescale: 600)
        let assetDuration = (try? await asset.load(.duration)) ?? .indefinite
        reader.timeRange = CMTimeRange(
            start: .zero,
            duration: assetDuration.seconds > 30 ? maxDuration : assetDuration
        )

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        reader.add(output)
        
        guard reader.startReading() else { return [] }
        
        var samples: [Float] = []
        
        while reader.status == .reading {
            guard let buffer = output.copyNextSampleBuffer(),
                  let blockBuffer = CMSampleBufferGetDataBuffer(buffer) else {
                break
            }
            
            let length = CMBlockBufferGetDataLength(blockBuffer)
            var data = Data(count: length)
            _ = data.withUnsafeMutableBytes { (pointer: UnsafeMutableRawBufferPointer) in
                CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: pointer.baseAddress!)
            }
            
            data.withUnsafeBytes { (pointer: UnsafeRawBufferPointer) in
                let int16Pointer = pointer.bindMemory(to: Int16.self)
                for i in 0..<int16Pointer.count {
                    // Normalize to 0...1
                    let sample = Float(abs(int16Pointer[i])) / Float(Int16.max)
                    samples.append(sample)
                }
            }
        }
        
        if reader.status == .failed {
            reader.cancelReading()
            return []
        }
        
        guard !samples.isEmpty else { return [] }
        
        // Downsample to the requested count using peak (max) instead of average,
        // which makes the waveform look much better for sparse or quiet audio.
        let chunkSize = samples.count / count
        var downsampled: [Float] = []
        if chunkSize > 1 {
            for i in 0..<count {
                let start = i * chunkSize
                let end = min(start + chunkSize, samples.count)
                let chunk = samples[start..<end]
                let peak = chunk.max() ?? 0.0
                downsampled.append(peak)
            }
        } else {
            downsampled = samples
        }
        
        // Normalize so the loudest peak is 1.0 (makes quiet recordings visible)
        let globalPeak = downsampled.max() ?? 1.0
        if globalPeak > 0 {
            downsampled = downsampled.map { $0 / globalPeak }
        }
        
        return downsampled
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
