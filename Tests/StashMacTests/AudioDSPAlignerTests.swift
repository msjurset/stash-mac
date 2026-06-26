import Foundation
import Testing
import AVFoundation
@testable import StashMac

@Suite struct AudioDSPAlignerTests {
    
    @Test func testExtractEnvelope() {
        // Create 1000 samples of constant 1.0 amplitude
        let samples = [Float](repeating: 1.0, count: 1000)
        
        // Downsample 1000Hz to 100Hz -> should yield exactly 100 envelope samples of value 1.0
        let envelope = AudioDSPAligner.extractEnvelope(samples, sampleRate: 1000.0, targetRate: 100.0)
        
        #expect(envelope.count == 100)
        for val in envelope {
            #expect(abs(val - 1.0) < 0.001)
        }
    }
    
    @Test func testCalculateAlignmentDelay() async throws {
        let sampleRate: Double = 44100.0
        let duration: Double = 8.0
        let pulseDuration: Double = 1.0
        
        // Master pulse starts at 2.0 seconds
        let masterStart = 2.0
        let expectedDelay = 0.5234 // 523.4 ms delay (well within coarse and fine search bounds)
        let sourceStart = masterStart + expectedDelay
        
        let masterSamples = generatePulse(sampleRate: sampleRate, duration: duration, startOffset: masterStart, pulseDuration: pulseDuration)
        let sourceSamples = generatePulse(sampleRate: sampleRate, duration: duration, startOffset: sourceStart, pulseDuration: pulseDuration)
        
        let tempDir = FileManager.default.temporaryDirectory
        let masterURL = tempDir.appendingPathComponent("master_test_\(UUID().uuidString).wav")
        let sourceURL = tempDir.appendingPathComponent("source_test_\(UUID().uuidString).wav")
        
        defer {
            try? FileManager.default.removeItem(at: masterURL)
            try? FileManager.default.removeItem(at: sourceURL)
        }
        
        try writeWavFile(url: masterURL, sampleRate: sampleRate, samples: masterSamples)
        try writeWavFile(url: sourceURL, sampleRate: sampleRate, samples: sourceSamples)
        
        // Calculate alignment delay using AudioDSPAligner
        let calculatedDelay = try await AudioDSPAligner.calculateAlignmentDelay(masterURL: masterURL, sourceURL: sourceURL)
        
        // Verify precision to within 1ms (0.001s)
        let difference = abs(calculatedDelay - expectedDelay)
        print("[Test] Expected: \(expectedDelay)s, Calculated: \(calculatedDelay)s, Diff: \(difference)s")
        #expect(difference < 0.001, "Alignment delay calculation error (\(difference)s) is greater than 1ms")
    }
    
    // MARK: - Helpers
    
    private func generatePulse(sampleRate: Double, duration: Double, startOffset: Double, pulseDuration: Double) -> [Float] {
        let totalSamples = Int(duration * sampleRate)
        var samples = [Float](repeating: 0.0, count: totalSamples)
        
        let pulseStart = Int(startOffset * sampleRate)
        let pulseLen = Int(pulseDuration * sampleRate)
        
        for i in 0..<pulseLen {
            let t = Double(i) / sampleRate
            let angle = 2.0 * .pi * 440.0 * t // 440 Hz tone
            let envelope = sin(.pi * Double(i) / Double(pulseLen)) // Smooth pulse shape
            let idx = pulseStart + i
            if idx < totalSamples {
                samples[idx] = Float(sin(angle) * envelope)
            }
        }
        
        return samples
    }
    
    private func writeWavFile(url: URL, sampleRate: Double, samples: [Float]) throws {
        // Use standard PCM wav settings
        let wavSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false
        ]
        
        let file = try AVAudioFile(forWriting: url, settings: wavSettings)
        let format = file.processingFormat
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        
        let channelData = buffer.floatChannelData![0]
        for i in 0..<samples.count {
            channelData[i] = samples[i]
        }
        
        try file.write(from: buffer)
    }
}
