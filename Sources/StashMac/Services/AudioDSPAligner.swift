import Foundation
import AVFoundation
import Accelerate

/// Performs audio track alignment using envelope-based normalized cross-correlation.
enum AudioDSPAligner {
    
    /// Finds the playback offset (in seconds) of a source audio track relative to a master mix.
    /// Returns the delay in seconds. If positive, the source track lags behind master. If negative, it is ahead.
    static func calculateAlignmentDelay(masterURL: URL, sourceURL: URL, maxDelaySeconds: Double = 15.0) async throws -> Double {
        print("[DSP] Aligning source \(sourceURL.lastPathComponent) to master \(masterURL.lastPathComponent)")
        
        return try await Task.detached(priority: .userInitiated) {
            // 1. Load PCM float buffers (read first 45 seconds to get a robust correlation footprint)
            let maxDurationSeconds: Double = 45.0
            let masterPCM = try loadPCM(from: masterURL, maxDuration: maxDurationSeconds)
            let sourcePCM = try loadPCM(from: sourceURL, maxDuration: maxDurationSeconds)
            
            guard !masterPCM.samples.isEmpty && !sourcePCM.samples.isEmpty else {
                throw NSError(domain: "AudioDSPAligner", code: 3, userInfo: [NSLocalizedDescriptionKey: "One of the audio tracks returned empty PCM data"])
            }
            
            // 2. Downsample PCM to 250Hz envelopes to make correlation blazing fast (4ms precision)
            let envelopeRate: Double = 250.0
            let masterFactor = Int(masterPCM.sampleRate / envelopeRate)
            let sourceFactor = Int(sourcePCM.sampleRate / envelopeRate)
            
            let masterEnv = extractEnvelope(masterPCM.samples, factor: max(1, masterFactor))
            let sourceEnv = extractEnvelope(sourcePCM.samples, factor: max(1, sourceFactor))
            
            // 3. Compute normalized cross-correlation
            let maxShift = Int(maxDelaySeconds * envelopeRate)
            let N = masterEnv.count
            let M = sourceEnv.count
            
            // Perform tight loop operations using unsafe pointers to bypass bounds checks and let the compiler vectorize the loop
            let bestShift = masterEnv.withUnsafeBufferPointer { masterBuf -> Int in
                sourceEnv.withUnsafeBufferPointer { sourceBuf -> Int in
                    let masterPtr = masterBuf.baseAddress!
                    let sourcePtr = sourceBuf.baseAddress!
                    
                    var currentBestShift = 0
                    var maxCorrelation: Float = -1.0
                    
                    for shift in -maxShift...maxShift {
                        let start = max(0, -shift)
                        let end = min(N, M - shift)
                        
                        guard (end - start) > 125 else { continue } // Ensure sufficient overlap (at least 0.5s at 250Hz)
                        
                        var dotProduct: Float = 0
                        var energyMaster: Float = 0
                        var energySource: Float = 0
                        
                        for i in start..<end {
                            let j = i + shift
                            let a = masterPtr[i]
                            let b = sourcePtr[j]
                            dotProduct += a * b
                            energyMaster += a * a
                            energySource += b * b
                        }
                        
                        let denom = sqrt(energyMaster * energySource)
                        let normCorr = denom > 0.001 ? (dotProduct / denom) : 0
                        
                        if normCorr > maxCorrelation {
                            maxCorrelation = normCorr
                            currentBestShift = shift
                        }
                    }
                    return currentBestShift
                }
            }
            
            let delaySeconds = Double(bestShift) / envelopeRate
            print("[DSP] Found alignment delay: \(String(format: "%.3f", delaySeconds))s")
            return delaySeconds
        }.value
    }
    
    /// Combines all source URLs, aligns them relative to the masterURL, mixes them offline,
    /// and writes the output as an AAC (.m4a) file to `outputURL`.
    static func alignAndMixTracks(
        masterURL: URL,
        sourceURLs: [URL],
        outputURL: URL,
        enhanceSpeech: Bool,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        print("[DSP] Starting align and mix process...")
        
        try await Task.detached(priority: .userInitiated) {
            // 1. Calculate alignment delays for all source tracks
            var delays: [URL: Double] = [:]
            delays[masterURL] = 0.0
            
            for (index, sourceURL) in sourceURLs.enumerated() {
                progress(Double(index) / Double(sourceURLs.count) * 0.3) // 30% of progress for alignment
                do {
                    let delay = try await calculateAlignmentDelay(masterURL: masterURL, sourceURL: sourceURL)
                    delays[sourceURL] = delay
                } catch {
                    print("[DSP] Warning: Failed to calculate delay for \(sourceURL.lastPathComponent): \(error)")
                    delays[sourceURL] = 0.0 // Default to no delay if alignment fails
                }
            }
            
            // 2. Compute the minimum delay to shift all tracks to be >= 0
            let minDelay = delays.values.min() ?? 0.0
            print("[DSP] Delays: \(delays)")
            print("[DSP] Min delay: \(minDelay)")
            
            // 3. Initialize AVAudioEngine
            let audioEngine = AVAudioEngine()
            
            // Load the master file to get format information
            let masterFile = try AVAudioFile(forReading: masterURL)
            let renderFormat = masterFile.processingFormat
            
            // Connect nodes
            var playerNodes: [AVAudioPlayerNode] = []
            var maxDuration: Double = 0.0
            let allURLs = [masterURL] + sourceURLs
            
            for url in allURLs {
                let file = try AVAudioFile(forReading: url)
                
                let delay = delays[url] ?? 0.0
                let offset = delay - minDelay
                let fileDuration = Double(file.length) / file.processingFormat.sampleRate
                maxDuration = max(maxDuration, offset + fileDuration)
                
                let playerNode = AVAudioPlayerNode()
                audioEngine.attach(playerNode)
                
                if enhanceSpeech {
                    let eq = AVAudioUnitEQ(numberOfBands: 3)
                    audioEngine.attach(eq)
                    
                    // Configure EQ bands to enhance speech clarity
                    // Band 0: High-pass filter (120 Hz) to cut low-frequency rumble
                    eq.bands[0].filterType = .highPass
                    eq.bands[0].frequency = 120.0
                    eq.bands[0].bypass = false
                    
                    // Band 1: Parametric band to boost vocal presence (2500 Hz, Q=1.5, +4dB)
                    eq.bands[1].filterType = .parametric
                    eq.bands[1].frequency = 2500.0
                    eq.bands[1].bandwidth = 1.5
                    eq.bands[1].gain = 4.0
                    eq.bands[1].bypass = false
                    
                    // Band 2: Low-pass filter (8000 Hz) to cut high-frequency hiss
                    eq.bands[2].filterType = .lowPass
                    eq.bands[2].frequency = 8000.0
                    eq.bands[2].bypass = false
                    
                    audioEngine.connect(playerNode, to: eq, format: file.processingFormat)
                    audioEngine.connect(eq, to: audioEngine.mainMixerNode, format: file.processingFormat)
                } else {
                    // Connect directly to main mixer. Let AVAudioEngine handle format conversions automatically.
                    audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: file.processingFormat)
                }
                
                playerNodes.append(playerNode)
                
                // Schedule
                let startFrame = AVAudioFramePosition(offset * file.processingFormat.sampleRate)
                let playTime = AVAudioTime(sampleTime: startFrame, atRate: file.processingFormat.sampleRate)
                playerNode.scheduleFile(file, at: playTime, completionHandler: nil)
            }
            
            print("[DSP] Total duration of mix: \(maxDuration)s")
            
            // 4. Set up manual rendering to output format
            let maxFrames: AVAudioFrameCount = 4096
            
            // Delete output file if it exists so we can create a fresh one
            if FileManager.default.fileExists(atPath: outputURL.path) {
                try? FileManager.default.removeItem(at: outputURL)
            }
            
            let aacSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: renderFormat.sampleRate,
                AVNumberOfChannelsKey: renderFormat.channelCount,
                AVEncoderBitRateKey: 192000
            ]
            
            let outputFile = try AVAudioFile(forWriting: outputURL, settings: aacSettings)
            let writeFormat = outputFile.processingFormat
            
            try audioEngine.enableManualRenderingMode(.offline, format: writeFormat, maximumFrameCount: maxFrames)
            
            // Start engine and players
            try audioEngine.start()
            playerNodes.forEach { $0.play() }
            
            // 5. Render loop
            let buffer = AVAudioPCMBuffer(pcmFormat: writeFormat, frameCapacity: maxFrames)!
            let totalFramesToRender = AVAudioFramePosition(maxDuration * writeFormat.sampleRate)
            var renderedFrames: AVAudioFramePosition = 0
            
            renderLoop: while renderedFrames < totalFramesToRender {
                let framesToRender = min(maxFrames, AVAudioFrameCount(totalFramesToRender - renderedFrames))
                let status = try audioEngine.renderOffline(framesToRender, to: buffer)
                
                switch status {
                case .success:
                    try outputFile.write(from: buffer)
                    renderedFrames += AVAudioFramePosition(framesToRender)
                    
                    let renderProgress = 0.3 + (Double(renderedFrames) / Double(totalFramesToRender) * 0.7)
                    progress(renderProgress)
                    
                case .insufficientDataFromInputNode:
                    // For file-based rendering, this shouldn't block, but break/finish if we are done
                    break renderLoop
                    
                case .cannotDoInCurrentContext:
                    throw NSError(domain: "AudioDSPAligner", code: 10, userInfo: [NSLocalizedDescriptionKey: "Render failed: cannot do in current context"])
                    
                case .error:
                    throw NSError(domain: "AudioDSPAligner", code: 11, userInfo: [NSLocalizedDescriptionKey: "Render error occurred"])
                    
                @unknown default:
                    break
                }
            }
            
            playerNodes.forEach { $0.stop() }
            audioEngine.stop()
            print("[DSP] Align and mix process completed successfully!")
        }.value
    }
    
    private struct AudioPCMData {
        let samples: [Float]
        let sampleRate: Double
    }
    
    private static func loadPCM(from url: URL, maxDuration: Double) throws -> AudioPCMData {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let nativeRate = format.sampleRate
        
        // Cap frame capacity to avoid loading massive files into RAM
        let frameCount = min(AVAudioFrameCount(file.length), AVAudioFrameCount(maxDuration * nativeRate))
        guard frameCount > 0 else {
            return AudioPCMData(samples: [], sampleRate: nativeRate)
        }
        
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw NSError(domain: "AudioDSPAligner", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to allocate audio PCM buffer"])
        }
        
        try file.read(into: buffer, frameCount: frameCount)
        
        guard let floatChannelData = buffer.floatChannelData else {
            throw NSError(domain: "AudioDSPAligner", code: 5, userInfo: [NSLocalizedDescriptionKey: "Audio channel format is not Float PCM"])
        }
        
        let ptr = floatChannelData[0]
        let count = Int(buffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: ptr, count: count))
        
        return AudioPCMData(samples: samples, sampleRate: nativeRate)
    }
    
    /// Extracts a volume envelope (rectified average) by downsampling the PCM data.
    private static func extractEnvelope(_ samples: [Float], factor: Int) -> [Float] {
        let length = samples.count / factor
        guard length > 0 else { return [] }
        
        var envelope = [Float](repeating: 0, count: length)
        for i in 0..<length {
            var sum: Float = 0
            let startIdx = i * factor
            for j in 0..<factor {
                sum += abs(samples[startIdx + j])
            }
            envelope[i] = sum / Float(factor)
        }
        return envelope
    }
}
