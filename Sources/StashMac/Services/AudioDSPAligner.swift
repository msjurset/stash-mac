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
            let masterEnv = extractEnvelope(masterPCM.samples, sampleRate: masterPCM.sampleRate, targetRate: envelopeRate)
            let sourceEnv = extractEnvelope(sourcePCM.samples, sampleRate: sourcePCM.sampleRate, targetRate: envelopeRate)
            
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
            
            let coarseDelay = Double(bestShift) / envelopeRate
            print("[DSP] Coarse alignment delay: \(String(format: "%.3f", coarseDelay))s")
            
            // 4. Refine alignment using a high-resolution 10kHz envelope (0.1ms precision)
            let fineEnvelopeRate: Double = 10000.0
            let masterFineEnv = extractEnvelope(masterPCM.samples, sampleRate: masterPCM.sampleRate, targetRate: fineEnvelopeRate)
            let sourceFineEnv = extractEnvelope(sourcePCM.samples, sampleRate: sourcePCM.sampleRate, targetRate: fineEnvelopeRate)
            
            let NFine = masterFineEnv.count
            let MFine = sourceFineEnv.count
            
            let coarseFineShift = Int(coarseDelay * fineEnvelopeRate)
            // Search range of +/- 15ms (150 samples at 10000Hz) around the coarse delay
            let fineSearchWindow = 150
            
            let bestFineShift = masterFineEnv.withUnsafeBufferPointer { masterBuf -> Int in
                sourceFineEnv.withUnsafeBufferPointer { sourceBuf -> Int in
                    let masterPtr = masterBuf.baseAddress!
                    let sourcePtr = sourceBuf.baseAddress!
                    
                    var currentBestShift = coarseFineShift
                    var maxCorrelation: Float = -1.0
                    
                    for shiftOffset in -fineSearchWindow...fineSearchWindow {
                        let shift = coarseFineShift + shiftOffset
                        let start = max(0, -shift)
                        let end = min(NFine, MFine - shift)
                        
                        guard (end - start) > 5000 else { continue } // at least 0.5s overlap (5000 samples at 10kHz)
                        
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
            
            let delaySeconds = Double(bestFineShift) / fineEnvelopeRate
            print("[DSP] Refined alignment delay: \(String(format: "%.6f", delaySeconds))s")
            return delaySeconds
        }.value
    }
    
    enum MixMode: String, Codable, Sendable {
        case linear
        case adaptive
    }

    struct TrackMixInfo: Sendable {
        let url: URL
        let isSelected: Bool
        let volume: Double
    }
    
    /// Combines all source URLs, aligns them relative to the masterURL, mixes them offline,
    /// and writes the output as an AAC (.m4a) file to `outputURL`.
    static func alignAndMixTracks(
        masterTrack: TrackMixInfo,
        sourceTracks: [TrackMixInfo],
        outputURL: URL,
        enhanceSpeech: Bool,
        mixMode: MixMode = .adaptive,
        noiseFloorGate: Float = 0.012,
        voiceThreshold: Float = 0.035,
        gateHoldTimeMs: Double = 160.0,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        print("[DSP] Starting align and mix process...")
        
        let masterURL = masterTrack.url
        let sourceURLs = sourceTracks.map { $0.url }
        
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
            
            let selectedSources = sourceTracks.filter { $0.isSelected }
            
            // 3. Perform Adaptive Mix or Linear Mix
            if mixMode == .adaptive && selectedSources.count == 2 {
                let track1 = selectedSources[0]
                let track2 = selectedSources[1]
                
                print("[DSP] Performing in-memory Adaptive Mix...")
                
                let pcm1 = try loadPCM(from: track1.url, maxDuration: 99999.0)
                let pcm2 = try loadPCM(from: track2.url, maxDuration: 99999.0)
                
                let delay1 = delays[track1.url] ?? 0.0
                let delay2 = delays[track2.url] ?? 0.0
                let offset1 = delay1 - minDelay
                let offset2 = delay2 - minDelay
                
                let sampleRate = pcm1.sampleRate
                let shift1 = Int(offset1 * sampleRate)
                let shift2 = Int(offset2 * sampleRate)
                
                let aligned1 = [Float](repeating: 0, count: shift1) + pcm1.samples
                let aligned2 = [Float](repeating: 0, count: shift2) + pcm2.samples
                
                let trackA_samples = aligned1
                let trackB_samples = aligned2
                
                let volumeA = Float(track1.volume)
                let volumeB = Float(track2.volume)
                
                let mixedSamples = mixTracks(
                    trackA: trackA_samples,
                    trackB: trackB_samples,
                    sampleRate: sampleRate,
                    noiseFloorGate: noiseFloorGate,
                    voiceThreshold: voiceThreshold,
                    gateHoldTimeMs: gateHoldTimeMs,
                    volumeA: volumeA,
                    volumeB: volumeB
                )
                
                let tempDir = FileManager.default.temporaryDirectory
                let tempMixURL = tempDir.appendingPathComponent("\(UUID().uuidString).m4a")
                
                if FileManager.default.fileExists(atPath: tempMixURL.path) {
                    try? FileManager.default.removeItem(at: tempMixURL)
                }
                
                try savePCM(samples: mixedSamples, sampleRate: sampleRate, channelCount: 1, to: tempMixURL)
                
                if enhanceSpeech {
                    print("[DSP] Applying Speech Enhancement (EQ) to adaptive mix...")
                    let tempEQURL = tempDir.appendingPathComponent("\(UUID().uuidString).m4a")
                    try applyEQ(inputURL: tempMixURL, outputURL: tempEQURL)
                    try? FileManager.default.removeItem(at: tempMixURL)
                    try FileManager.default.moveItem(at: tempEQURL, to: tempMixURL)
                }
                
                if FileManager.default.fileExists(atPath: outputURL.path) {
                    try? FileManager.default.removeItem(at: outputURL)
                }
                try FileManager.default.moveItem(at: tempMixURL, to: outputURL)
                progress(1.0)
            } else {
                print("[DSP] Performing Linear Mix via AVAudioEngine...")
                guard !selectedSources.isEmpty else {
                    throw NSError(domain: "AudioDSPAligner", code: 22, userInfo: [NSLocalizedDescriptionKey: "No source tracks selected to mix"])
                }
                
                // Initialize AVAudioEngine
                let audioEngine = AVAudioEngine()
                
                // Load the master file to get format information
                let masterFile = try AVAudioFile(forReading: masterURL)
                let renderFormat = masterFile.processingFormat
                
                // Connect nodes
                var playerNodes: [AVAudioPlayerNode] = []
                var maxDuration: Double = 0.0
                
                for track in selectedSources {
                    let file = try AVAudioFile(forReading: track.url)
                    
                    let delay = delays[track.url] ?? 0.0
                    let offset = delay - minDelay
                    let fileDuration = Double(file.length) / file.processingFormat.sampleRate
                    maxDuration = max(maxDuration, offset + fileDuration)
                    
                    let playerNode = AVAudioPlayerNode()
                    audioEngine.attach(playerNode)
                    
                    if enhanceSpeech {
                        let eq = AVAudioUnitEQ(numberOfBands: 3)
                        audioEngine.attach(eq)
                        
                        // Configure EQ bands to enhance speech clarity
                        eq.bands[0].filterType = .highPass
                        eq.bands[0].frequency = 120.0
                        eq.bands[0].bypass = false
                        
                        eq.bands[1].filterType = .parametric
                        eq.bands[1].frequency = 2500.0
                        eq.bands[1].bandwidth = 1.5
                        eq.bands[1].gain = 4.0
                        eq.bands[1].bypass = false
                        
                        eq.bands[2].filterType = .lowPass
                        eq.bands[2].frequency = 8000.0
                        eq.bands[2].bypass = false
                        
                        audioEngine.connect(playerNode, to: eq, format: file.processingFormat)
                        audioEngine.connect(eq, to: audioEngine.mainMixerNode, format: file.processingFormat)
                    } else {
                        // Connect directly to main mixer
                        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: file.processingFormat)
                    }
                    
                    // Set the volume based on track volume level
                    playerNode.volume = Float(track.volume)
                    
                    playerNodes.append(playerNode)
                    
                    // Schedule
                    let startFrame = AVAudioFramePosition(offset * file.processingFormat.sampleRate)
                    let playTime = AVAudioTime(sampleTime: startFrame, atRate: file.processingFormat.sampleRate)
                    playerNode.scheduleFile(file, at: playTime, completionHandler: nil)
                }
                
                print("[DSP] Total duration of mix: \(maxDuration)s")
                
                // Set up manual rendering to output format
                let maxFrames: AVAudioFrameCount = 4096
                
                // Delete output file if it exists
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
                
                // Render loop
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
            }
        }.value
    }

    private static func savePCM(samples: [Float], sampleRate: Double, channelCount: AVAudioChannelCount, to url: URL) throws {
        let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channelCount, interleaved: false)!
        let aacSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVEncoderBitRateKey: 192000
        ]
        let file = try AVAudioFile(forWriting: url, settings: aacSettings, commonFormat: .pcmFormatFloat32, interleaved: false)
        
        let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channelData = buffer.floatChannelData![0]
        for i in 0..<samples.count {
            channelData[i] = samples[i]
        }
        try file.write(from: buffer)
    }

    private static func mixTracks(
        trackA: [Float],
        trackB: [Float],
        sampleRate: Double,
        noiseFloorGate: Float,
        voiceThreshold: Float,
        gateHoldTimeMs: Double,
        volumeA: Float,
        volumeB: Float,
        phoneWeightMax: Float = 0.90,
        watchWeightMax: Float = 0.50
    ) -> [Float] {
        let length = min(trackA.count, trackB.count)
        var mixed = [Float](repeating: 0, count: length)
        
        // Window size for energy calculation (20ms)
        let windowSize = max(1, Int(sampleRate * 0.02))
        let windowDuration = Double(windowSize) / sampleRate
        
        // Hysteresis/Hold counter to prevent noise gate chatter
        var gateClosedCounter = 0
        let gateHoldLimit = max(1, Int(gateHoldTimeMs / 1000.0 / windowDuration))

        // For smoothing gain transitions
        var lastPhoneGain = phoneWeightMax * volumeA
        var lastWatchGain: Float = 0.1 * volumeB
        var lastWinner: Float = 0.0 // 0.0 = Phone, 1.0 = Watch

        var i = 0
        while i < length {
            let end = min(i + windowSize, length)
            let windowLength = end - i
            
            // Calculate Root Mean Square (RMS) energy for the current window
            var sumSquareA: Double = 0.0
            var sumSquareB: Double = 0.0
            for j in i..<end {
                let valA = trackA[j]
                let valB = trackB[j]
                sumSquareA += Double(valA * valA)
                sumSquareB += Double(valB * valB)
            }
            
            let rmsA = Float(sqrt(sumSquareA / Double(windowLength)))
            let rmsB = Float(sqrt(sumSquareB / Double(windowLength)))
            
            // Switcher Logic: Pick the best track for this window
            let targetWinner: Float
            if rmsB > rmsA * 1.5 && rmsB > voiceThreshold {
                targetWinner = 1.0
            } else if rmsA > voiceThreshold {
                targetWinner = 0.0
            } else if rmsB > voiceThreshold {
                targetWinner = 1.0
            } else {
                targetWinner = rmsA >= rmsB ? 0.0 : 1.0
            }

            // Smoothly cross-fade to the new winner
            let fadeAlpha: Float = 0.4
            let winnerMix = (targetWinner * fadeAlpha) + (lastWinner * (1.0 - fadeAlpha))
            lastWinner = winnerMix

            let phoneGain = (1.0 - winnerMix) * phoneWeightMax * volumeA
            let watchGain = ((winnerMix * (watchWeightMax - 0.1)) + 0.1) * volumeB
            
            if rmsA < noiseFloorGate && rmsB < noiseFloorGate {
                gateClosedCounter += 1
            } else {
                gateClosedCounter = 0
            }

            let activePhoneGain: Float
            let activeWatchGain: Float
            if gateClosedCounter >= gateHoldLimit {
                activePhoneGain = 0.05 * volumeA
                activeWatchGain = 0.02 * volumeB
            } else {
                activePhoneGain = phoneGain
                activeWatchGain = watchGain
            }

            // Mix with linear gain smoothing across the window
            for j in i..<end {
                let k = j - i
                let fraction = Float(k + 1) / Float(windowLength)
                let currentPhoneGain = lastPhoneGain + (activePhoneGain - lastPhoneGain) * fraction
                let currentWatchGain = lastWatchGain + (activeWatchGain - lastWatchGain) * fraction
                
                let sampleA = trackA[j] * currentPhoneGain
                let sampleB = trackB[j] * currentWatchGain
                
                let sum = sampleA + sampleB
                mixed[j] = max(-1.0, min(1.0, sum))
            }
            
            lastPhoneGain = activePhoneGain
            lastWatchGain = activeWatchGain
            
            i += windowSize
        }
        
        return mixed
    }

    private static func applyEQ(inputURL: URL, outputURL: URL) throws {
        let audioEngine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()
        let eq = AVAudioUnitEQ(numberOfBands: 3)
        
        audioEngine.attach(playerNode)
        audioEngine.attach(eq)
        
        eq.bands[0].filterType = .highPass
        eq.bands[0].frequency = 120.0
        eq.bands[0].bypass = false
        
        eq.bands[1].filterType = .parametric
        eq.bands[1].frequency = 2500.0
        eq.bands[1].bandwidth = 1.5
        eq.bands[1].gain = 4.0
        eq.bands[1].bypass = false
        
        eq.bands[2].filterType = .lowPass
        eq.bands[2].frequency = 8000.0
        eq.bands[2].bypass = false
        
        let file = try AVAudioFile(forReading: inputURL)
        let format = file.processingFormat
        
        audioEngine.connect(playerNode, to: eq, format: format)
        audioEngine.connect(eq, to: audioEngine.mainMixerNode, format: format)
        
        let maxFrames: AVAudioFrameCount = 4096
        let renderFormat = file.processingFormat
        let aacSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: renderFormat.sampleRate,
            AVNumberOfChannelsKey: renderFormat.channelCount,
            AVEncoderBitRateKey: 192000
        ]
        
        let outputFile = try AVAudioFile(forWriting: outputURL, settings: aacSettings)
        let writeFormat = outputFile.processingFormat
        
        try audioEngine.enableManualRenderingMode(.offline, format: writeFormat, maximumFrameCount: maxFrames)
        
        try audioEngine.start()
        playerNode.play()
        playerNode.scheduleFile(file, at: nil, completionHandler: nil)
        
        let buffer = AVAudioPCMBuffer(pcmFormat: writeFormat, frameCapacity: maxFrames)!
        let totalFrames = file.length
        var renderedFrames: AVAudioFramePosition = 0
        
        while renderedFrames < totalFrames {
            let framesToRender = min(maxFrames, AVAudioFrameCount(totalFrames - renderedFrames))
            let status = try audioEngine.renderOffline(framesToRender, to: buffer)
            if status == .success {
                try outputFile.write(from: buffer)
                renderedFrames += AVAudioFramePosition(framesToRender)
            } else {
                break
            }
        }
        
        playerNode.stop()
        audioEngine.stop()
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
    
    /// Extracts a volume envelope (rectified average) by downsampling the PCM data to a specific target sample rate.
    static func extractEnvelope(_ samples: [Float], sampleRate: Double, targetRate: Double) -> [Float] {
        let step = sampleRate / targetRate
        let length = Int(Double(samples.count) / step)
        guard length > 0 else { return [] }
        
        // Use a 15ms smoothing window to eliminate high-frequency carrier ripple
        let windowSize = max(1, Int(sampleRate * 0.015))
        let halfWindow = windowSize / 2
        
        var envelope = [Float](repeating: 0, count: length)
        for i in 0..<length {
            let centerIdx = Int(Double(i) * step)
            let startIdx = max(0, centerIdx - halfWindow)
            let endIdx = min(samples.count, centerIdx + halfWindow)
            let count = endIdx - startIdx
            guard count > 0 else { continue }
            
            var sum: Float = 0
            for j in startIdx..<endIdx {
                sum += abs(samples[j])
            }
            envelope[i] = sum / Float(count)
        }
        return envelope
    }
}
