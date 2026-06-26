import SwiftUI
import AVFoundation

/// A multi-track waveform visualizer with dynamic "Lens" magnification,
/// recursive zooming, and synchronized multi-track playback.
struct XRayAudioView: View {
    let item: StashItem
    let onDismiss: () -> Void

    @Environment(StashStore.self) private var store

    @State private var tracks: [XRayTrack] = []
    @State private var cursorPosition: CGFloat = 0 
    @State private var isHovering = false
    @State private var zoomLevel: Double = 0 
    @State private var containerWidth: CGFloat = 800
    @State private var loadingStatus: String = "Initializing analyzer..."
    @State private var diagnosticLog: [LogEntry] = []
    @State private var errorMessage: String? = nil
    @State private var cliVersion: String = "Detecting..."
    
    // Selection/Zoom State
    @State private var dragStart: CGPoint? = nil
    @State private var dragCurrent: CGPoint? = nil
    @State private var currentTimeRange: CMTimeRange? = nil
    @State private var zoomHistory: [CMTimeRange] = []
    
    // Hover states for handles
    @State private var isHoveringPlayhead = false
    @State private var isHoveringLoopStart = false
    @State private var isHoveringLoopEnd = false
    
    // Loop / stop bounds
    @State private var loopStartPoint: Double = 0.0
    @State private var loopEndPoint: Double? = nil
    @State private var dragStartLoopStart: Double? = nil
    @State private var dragStartLoopEnd: Double? = nil
    
    // Playback State (AVAudioEngine for robust multi-track mixing)
    @State private var audioEngine = AVAudioEngine()
    @State private var subMixer = AVAudioMixerNode()
    @State private var timePitch = AVAudioUnitTimePitch()
    @State private var playerNodes: [UUID: AVAudioPlayerNode] = [:]
    @State private var audioFiles: [UUID: AVAudioFile] = [:]
    @State private var tempURLs: [URL] = []
    
    @State private var isPlaying = false
    @State private var playbackTime: Double = 0 
    @State private var playbackSpeed: Double = 1.0
    @State private var isLooping = true
    @State private var timeObserver: Any?
    @State private var totalFileDuration: Double = 0
    
    // Timer for playhead movement since AVAudioEngine doesn't have periodic observers
    @State private var playheadTimer: Timer?
    @State private var startTime: Double = 0
    @State private var dragStartPlayheadTime: Double? = nil

    // Optimize Mix state
    @State private var isOptimizing = false
    @State private var optimizingProgress: Double = 0.0
    
    // Caption Editing State
    @State private var editingTrackID: UUID? = nil
    @State private var draftCaption: String = ""
    @State private var enhanceSpeech = false

    struct LogEntry: Identifiable {
        let id = UUID()
        let timestamp = Date()
        let message: String
        var display: String {
            "\(timestamp.formatted(.dateTime.hour().minute().second())): \(message)"
        }
    }
    
    @State private var lensWidth: Double = 200.0
    @State private var magnification: Double = 6.0
    
    private func log(_ msg: String) {
        print("[X-RAY] \(msg)")
        diagnosticLog.append(LogEntry(message: msg))
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header
                
                if let error = errorMessage {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(.orange)
                        Text("Analysis Failed")
                            .font(.headline)
                        Text(error)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Diagnostic Log:")
                                .font(.caption)
                                .bold()
                            Text("CLI Version: \(cliVersion)")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(Color.accentColor)
                            ForEach(diagnosticLog.suffix(10)) { entry in
                                Text(entry.display)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding()
                        .background(Color.black.opacity(0.2))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .frame(maxWidth: 400)

                        HStack(spacing: 12) {
                            Button("Retry") {
                                errorMessage = nil
                                loadTracks()
                            }
                            .buttonStyle(.bordered)
                            
                            Button("Refresh Item") {
                                Task { await refreshItem() }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if tracks.isEmpty {
                    VStack(spacing: 20) {
                        ProgressView()
                            .scaleEffect(1.5)
                        Text(loadingStatus)
                            .font(.headline)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("CLI Version: \(cliVersion)")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(Color.accentColor)
                            ForEach(diagnosticLog.suffix(15)) { entry in
                                Text(entry.display)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding()
                        .background(Color.black.opacity(0.2))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .frame(maxWidth: 400)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal) {
                            ZStack(alignment: .topLeading) {
                                VStack(spacing: 12) {
                                    // 0. Timeline Ruler
                                    TimelineRulerView(
                                        contentWidth: contentWidth,
                                        currentTimeRange: currentTimeRange,
                                        totalDuration: totalFileDuration,
                                        cursorPosition: $cursorPosition,
                                        isHovering: $isHovering,
                                        onSeekPercent: { seekToPercent($0) }
                                    )
                                    .padding(.horizontal, 8)
                                    
                                    // 1. Composite Layer with Interactive Legend
                                    if let composite = createCompositeTrack() {
                                        CompositeWaveformView(
                                            composite: composite,
                                            tracks: $tracks,
                                            cursorPosition: $cursorPosition,
                                            lensWidth: CGFloat(lensWidth),
                                            magnification: CGFloat(magnification),
                                            isHovering: $isHovering,
                                            contentWidth: contentWidth,
                                            currentTimeRange: currentTimeRange,
                                            dragStart: $dragStart,
                                            dragCurrent: $dragCurrent,
                                            editingTrackID: $editingTrackID,
                                            draftCaption: $draftCaption,
                                            commitCaptionEdit: commitCaptionEdit,
                                            onSeekPercent: { seekToPercent($0) },
                                            onZoomEnded: { startPct, endPct in
                                                handleZoomToSelection(startPct: startPct, endPct: endPct)
                                            }
                                        )
                                        .frame(height: 180)
                                    }
                                    
                                    // Divider().background(Color.white.opacity(0.1))
                                    Divider().background(Color.white.opacity(0.1))
                                    
                                    // 2. Individual Tracks
                                    ForEach($tracks) { $track in
                                        WaveformTrackView(
                                            track: $track,
                                            cursorPosition: $cursorPosition,
                                            lensWidth: CGFloat(lensWidth),
                                            magnification: CGFloat(magnification),
                                            isHovering: $isHovering,
                                            contentWidth: contentWidth,
                                            currentTimeRange: currentTimeRange,
                                            dragStart: $dragStart,
                                            dragCurrent: $dragCurrent,
                                            onSeekPercent: { seekToPercent($0) },
                                            onZoomEnded: { startPct, endPct in
                                                handleZoomToSelection(startPct: startPct, endPct: endPct)
                                            }
                                        )
                                        .frame(height: 140)
                                        .onChange(of: track.isSelected) { _, newValue in
                                            updateMuteState(for: track)
                                        }
                                        .onChange(of: track.volume) { _, newValue in
                                            updateMuteState(for: track)
                                        }
                                    }
                                }
                                .frame(width: contentWidth)
                                .padding(.vertical, 8)
                                
                                // 1. Playhead Line (click-through, full-height)
                                let playheadX = calculatePlayheadX()
                                if playheadX >= 0 && playheadX <= contentWidth {
                                    Rectangle()
                                        .fill(Color.yellow)
                                        .frame(width: 2)
                                        .offset(x: playheadX)
                                        .allowsHitTesting(false)
                                        .zIndex(99)
                                }
                                
                                // 2. Loop Start Line (click-through, full-height)
                                let loopStartX = calculateX(for: loopStartPoint)
                                if loopStartX >= 0 && loopStartX <= contentWidth {
                                    Rectangle()
                                        .fill(Color.orange.opacity(0.6))
                                        .frame(width: 2)
                                        .offset(x: loopStartX)
                                        .allowsHitTesting(false)
                                        .zIndex(89)
                                }
                                
                                // 3. Loop End Line (click-through, full-height)
                                let loopEndX = calculateX(for: loopEndPoint ?? totalFileDuration)
                                if loopEndX >= 0 && loopEndX <= contentWidth {
                                    Rectangle()
                                        .fill(Color.orange.opacity(0.6))
                                        .frame(width: 2)
                                        .offset(x: loopEndX)
                                        .allowsHitTesting(false)
                                        .zIndex(89)
                                }
                                
                                // 4. Playhead Handle (top-only, height 32, width 44, interactive)
                                if playheadX >= 0 && playheadX <= contentWidth {
                                    Image(systemName: "play.fill")
                                        .font(.system(size: 16))
                                        .rotationEffect(.degrees(90))
                                        .foregroundStyle(Color.yellow)
                                        .offset(y: -4)
                                        .frame(width: 44, height: 32)
                                        .contentShape(Rectangle())
                                        .scaleEffect(isHoveringPlayhead ? 1.25 : 1.0)
                                        .onHover { isHoveringPlayhead = $0 }
                                        .resizeLeftRightCursor()
                                        .gesture(
                                            DragGesture(minimumDistance: 0)
                                                .onChanged { value in
                                                    if dragStartPlayheadTime == nil {
                                                        dragStartPlayheadTime = playbackTime
                                                    }
                                                    guard let startTime = dragStartPlayheadTime else { return }
                                                    let totalDur = tracks.map(\.duration).max() ?? 1.0
                                                    let displayDuration = currentTimeRange?.duration.seconds ?? totalDur
                                                    let deltaT = (Double(value.translation.width) / Double(contentWidth)) * displayDuration
                                                    let targetTime = max(0, min(startTime + deltaT, totalDur))
                                                    seek(to: targetTime)
                                                }
                                                .onEnded { _ in
                                                    dragStartPlayheadTime = nil
                                                }
                                        )
                                        .offset(x: playheadX - 22)
                                        .shadow(color: .black.opacity(0.3), radius: 2)
                                        .zIndex(100)
                                }
                                
                                // 5. Loop Start Handle (top-only, height 32, width 44, interactive)
                                if loopStartX >= 0 && loopStartX <= contentWidth {
                                    Image(systemName: "arrowtriangle.right.fill")
                                        .font(.system(size: 16))
                                        .foregroundStyle(Color.orange)
                                        .offset(y: -4)
                                        .frame(width: 44, height: 32)
                                        .contentShape(Rectangle())
                                        .scaleEffect(isHoveringLoopStart ? 1.25 : 1.0)
                                        .onHover { isHoveringLoopStart = $0 }
                                        .resizeLeftRightCursor()
                                        .gesture(
                                            DragGesture(minimumDistance: 0)
                                                .onChanged { value in
                                                    if dragStartLoopStart == nil {
                                                        dragStartLoopStart = loopStartPoint
                                                    }
                                                    guard let baseTime = dragStartLoopStart else { return }
                                                    let totalDur = tracks.map(\.duration).max() ?? 1.0
                                                    let displayDuration = currentTimeRange?.duration.seconds ?? totalDur
                                                    let deltaT = (Double(value.translation.width) / Double(contentWidth)) * displayDuration
                                                    let targetTime = max(0, min(baseTime + deltaT, (loopEndPoint ?? totalDur) - 0.1))
                                                    loopStartPoint = targetTime
                                                    
                                                    if playbackTime < targetTime {
                                                        seek(to: targetTime)
                                                    }
                                                }
                                                .onEnded { _ in
                                                    dragStartLoopStart = nil
                                                }
                                        )
                                        .offset(x: loopStartX - 22)
                                        .shadow(color: .black.opacity(0.3), radius: 1)
                                        .zIndex(90)
                                }
                                
                                // 6. Loop End Handle (top-only, height 32, width 44, interactive)
                                if loopEndX >= 0 && loopEndX <= contentWidth {
                                    Image(systemName: "arrowtriangle.left.fill")
                                        .font(.system(size: 16))
                                        .foregroundStyle(Color.orange)
                                        .offset(y: -4)
                                        .frame(width: 44, height: 32)
                                        .contentShape(Rectangle())
                                        .scaleEffect(isHoveringLoopEnd ? 1.25 : 1.0)
                                        .onHover { isHoveringLoopEnd = $0 }
                                        .resizeLeftRightCursor()
                                        .gesture(
                                            DragGesture(minimumDistance: 0)
                                                .onChanged { value in
                                                    if dragStartLoopEnd == nil {
                                                        dragStartLoopEnd = loopEndPoint ?? totalFileDuration
                                                    }
                                                    guard let baseTime = dragStartLoopEnd else { return }
                                                    let totalDur = tracks.map(\.duration).max() ?? 1.0
                                                    let displayDuration = currentTimeRange?.duration.seconds ?? totalDur
                                                    let deltaT = (Double(value.translation.width) / Double(contentWidth)) * displayDuration
                                                    let targetTime = max(loopStartPoint + 0.1, min(baseTime + deltaT, totalDur))
                                                    loopEndPoint = targetTime
                                                    
                                                    if playbackTime > targetTime {
                                                        seek(to: loopStartPoint)
                                                    }
                                                }
                                                .onEnded { _ in
                                                    dragStartLoopEnd = nil
                                                }
                                        )
                                        .offset(x: loopEndX - 22)
                                        .shadow(color: .black.opacity(0.3), radius: 1)
                                        .zIndex(90)
                                }
                                
                                SelectionHighlightOverlay(
                                    dragStart: $dragStart,
                                    dragCurrent: $dragCurrent
                                )
                                
                                HoverCursorOverlay(
                                    cursorPosition: $cursorPosition,
                                    isHovering: $isHovering,
                                    dragStart: $dragStart,
                                    contentWidth: contentWidth,
                                    tracks: tracks,
                                    currentTimeRange: currentTimeRange
                                )
                            }
                            .contentShape(Rectangle())
                            .onContinuousHover { phase in
                                DispatchQueue.main.async {
                                    switch phase {
                                    case .active(let location):
                                        cursorPosition = location.x
                                        isHovering = true
                                    case .ended:
                                        isHovering = false
                                    }
                                }
                            }
                        }
                        .background(
                            GeometryReader { proxy in
                                Color.clear.onAppear { containerWidth = proxy.size.width }
                            }
                        )
                    }
                }
            }
            .background(Color(NSColor.windowBackgroundColor))
            
            if isOptimizing {
                ZStack {
                    Color.black.opacity(0.4)
                        .background(.ultraThinMaterial)
                    
                    VStack(spacing: 20) {
                        ProgressView(value: optimizingProgress, total: 1.0)
                            .progressViewStyle(.linear)
                            .frame(width: 240)
                            .tint(Color.accentColor)
                        
                        Text(String(format: "Aligning & Mixing... %.0f%%", optimizingProgress * 100))
                            .font(.headline)
                            .foregroundStyle(.primary)
                        
                        Text("Locally analyzing acoustics and realigning waveforms")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(32)
                    .background(RoundedRectangle(cornerRadius: 16).fill(.thinMaterial))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
                .zIndex(1000)
            }
        }
        .onAppear {
            Task {
                await detectCLIVersion()
                await refreshItem()
                loadTracks()
            }
        }
        .onDisappear {
            stopPlayback()
        }
    }
    
    private var contentWidth: CGFloat {
        return containerWidth
    }
    
    private var header: some View {
        VStack(spacing: 8) {
            // Row 1: Title, Playback, and Optimize Mix
            HStack(spacing: 16) {
                Button(action: onDismiss) {
                    Image(systemName: "chevron.down.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                
                VStack(alignment: .leading) {
                    Text("X-Ray Audio Analyzer")
                        .font(.headline)
                    Text(item.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .fixedSize(horizontal: true, vertical: false)
                
                Spacer()
                
                // Playback Controls
                HStack(spacing: 12) {
                    Button(action: { isLooping.toggle() }) {
                        Image(systemName: isLooping ? "repeat.1" : "repeat")
                            .font(.system(size: 11))
                            .foregroundStyle(isLooping ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Toggle Loop")

                    Divider()
                        .frame(height: 12)
                        .background(Color.white.opacity(0.2))

                    // VCR backward end (Skip to Start)
                    Button(action: { seek(to: loopStartPoint) }) {
                        Image(systemName: "backward.end.fill")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .help("Skip to Start")

                    // VCR backward (Step Back 1s)
                    Button(action: { seek(to: playbackTime - 1.0) }) {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .help("Step Back 1s")

                    // Play / Pause
                    Button(action: togglePlayback) {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 20)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.space, modifiers: [])
                    .help("Play / Pause")

                    // VCR forward (Step Forward 1s)
                    Button(action: { seek(to: playbackTime + 1.0) }) {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .help("Step Forward 1s")

                    // VCR forward end (Skip to End)
                    Button(action: { seek(to: loopEndPoint ?? totalFileDuration) }) {
                        Image(systemName: "forward.end.fill")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .help("Skip to End")

                    Divider()
                        .frame(height: 12)
                        .background(Color.white.opacity(0.2))

                    // Speed Menu
                    Menu {
                        ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { speed in
                            Button("\(speed, specifier: "%.2f")x") {
                                playbackSpeed = speed
                                updatePlaybackSpeed(speed)
                            }
                        }
                    } label: {
                        Text("\(playbackSpeed, specifier: "%.1f")x")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.2))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 44)
                    .help("Playback Speed")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.2))
                .clipShape(Capsule())
                .fixedSize(horizontal: true, vertical: false)
                
                Spacer()
                
                if !tracks.isEmpty {
                    Toggle("Enhance Speech", isOn: $enhanceSpeech)
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                        .disabled(isOptimizing)
                        .fixedSize(horizontal: true, vertical: false)
                    
                    Button(action: runOptimizeMix) {
                        Label("Optimize Mix", systemImage: "wand.and.stars")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isOptimizing)
                    .fixedSize(horizontal: true, vertical: false)
                }
            }
            
            Divider()
                .opacity(0.1)
                .padding(.vertical, 2)
            
            // Row 2: Lens Adjustments, Diagnostics & Zoom History
            HStack(spacing: 16) {
                // Diagnostics status for debugging
                if let lastLog = diagnosticLog.last {
                    Text(lastLog.message)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.accentColor)
                        .lineLimit(1)
                        .frame(maxWidth: 200)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .fixedSize(horizontal: true, vertical: false)
                }
                
                Spacer()
                
                // Lens Size & Zoom (Magnification) Controls
                HStack(spacing: 12) {
                    HStack(spacing: 4) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text("Lens Width:")
                            .font(.system(size: 10, weight: .bold))
                        Slider(value: $lensWidth, in: 50...400)
                            .controlSize(.mini)
                            .frame(width: 100)
                        Text("\(Int(lensWidth))px")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 32, alignment: .trailing)
                    }
                    
                    Divider()
                        .frame(height: 12)
                    
                    HStack(spacing: 4) {
                        Text("Zoom:")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                        Slider(value: $magnification, in: 1.5...10.0)
                            .controlSize(.mini)
                            .frame(width: 80)
                        Text(String(format: "%.1fx", magnification))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, alignment: .trailing)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.2))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .fixedSize(horizontal: true, vertical: false)
                
                Spacer()
                
                if zoomLevel > 0 {
                    Button("Reset Zoom") {
                        zoomHistory = []
                        currentTimeRange = nil
                        if zoomLevel > 3 { zoomLevel = 0 }
                        else { withAnimation { zoomLevel = 0 } }
                        self.loopStartPoint = 0.0
                        self.loopEndPoint = self.totalFileDuration
                        seek(to: 0.0)
                    }
                    .controlSize(.small)
                    .fixedSize(horizontal: true, vertical: false)
                }
                
                Button(action: {
                    if !zoomHistory.isEmpty {
                        let prevRange = zoomHistory.removeLast()
                        withAnimation {
                            currentTimeRange = zoomHistory.isEmpty ? nil : prevRange
                            zoomLevel = Double(zoomHistory.count)
                        }
                        self.loopStartPoint = prevRange.start.seconds
                        self.loopEndPoint = prevRange.end.seconds
                        seek(to: prevRange.start.seconds)
                    }
                }) {
                    Label("Back", systemImage: "arrow.uturn.backward")
                }
                .disabled(zoomHistory.isEmpty)
                .controlSize(.small)
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }
    
    private func createCompositeTrack() -> XRayTrack? {
        guard !tracks.isEmpty else { return nil }
        return XRayTrack(
            label: "COMPOSITE X-RAY",
            url: nil,
            mime: nil,
            duration: tracks.map(\.duration).max() ?? 0,
            samples: [], 
            role: .composite,
            position: -1
        )
    }

    private func detectCLIVersion() async {
        do {
            let version = try await store.getCLIVersion()
            await MainActor.run { self.cliVersion = version }
            log("CLI: \(version)")
        } catch {
            log("CLI Error: \(error.localizedDescription)")
        }
    }

    private func togglePlayback() {
        if isPlaying {
            pausePlayback()
        } else {
            startPlayback()
        }
    }
    
    private func startPlayback() {
        if playerNodes.isEmpty { 
            log("Initializing engine...")
            setupPlayers() 
        }
        
        guard !playerNodes.isEmpty else { 
            log("ERROR: No player nodes to start")
            return 
        }
        
        log("PLAYING (\(playbackSpeed)x)")
        
        let startT = loopStartPoint
        let endT = loopEndPoint ?? totalFileDuration
        
        if playbackTime >= endT || playbackTime < startT {
            playbackTime = startT
        }
        
        for (id, playerNode) in playerNodes {
            guard let file = audioFiles[id] else { continue }
            
            playerNode.stop()
            
            let sampleRate = file.fileFormat.sampleRate
            let startFrame = Int64(playbackTime * sampleRate)
            
            if startFrame < file.length {
                let frameCount = AVAudioFrameCount(file.length - startFrame)
                
                playerNode.scheduleSegment(
                    file,
                    startingFrame: startFrame,
                    frameCount: frameCount,
                    at: nil,
                    completionHandler: nil
                )
                
                if let track = tracks.first(where: { $0.id == id }) {
                    playerNode.volume = track.isSelected ? Float(track.volume) : 0.0
                }
                
                playerNode.play()
            }
        }
        
        timePitch.rate = Float(playbackSpeed)
        
        let interval = 0.05
        let playheadStartRealTime = CACurrentMediaTime()
        let playheadStartAudioTime = playbackTime
        
        playheadTimer?.invalidate()
        playheadTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in
                let elapsed = CACurrentMediaTime() - playheadStartRealTime
                self.playbackTime = playheadStartAudioTime + elapsed * self.playbackSpeed
                
                let currentStart = self.loopStartPoint
                let currentEnd = self.loopEndPoint ?? self.totalFileDuration
                if self.playbackTime >= currentEnd {
                    if self.isLooping {
                        self.log("Looping...")
                        self.playbackTime = currentStart
                        self.startPlayback()
                    } else {
                        self.pausePlayback()
                    }
                }
            }
        }
        
        isPlaying = true
    }
    
    private func pausePlayback() {
        log("PAUSED")
        playheadTimer?.invalidate()
        playheadTimer = nil
        
        playerNodes.values.forEach { $0.pause() }
        isPlaying = false
    }

    private func updatePlaybackSpeed(_ speed: Double) {
        log("Speed: \(speed)x")
        let rate = Float(speed)
        timePitch.rate = rate
    }

    private func seekAll(to time: CMTime) {
        seek(to: time.seconds)
    }
    
    private func seek(to seconds: Double) {
        log("Seek: \(String(format: "%.2f", seconds))s")
        playbackTime = max(0, min(seconds, totalFileDuration))
        if isPlaying {
            startPlayback()
        }
    }
    
    private func seekToPercent(_ percent: Double) {
        let totalDur = tracks.map(\.duration).max() ?? 1.0
        let startOffset = currentTimeRange?.start.seconds ?? 0
        let displayDuration = currentTimeRange?.duration.seconds ?? totalDur
        let targetTime = startOffset + (percent * displayDuration)
        seek(to: targetTime)
    }
    
    private func updateMuteState(for track: XRayTrack) {
        if let playerNode = playerNodes[track.id] {
            playerNode.volume = track.isSelected ? Float(track.volume) : 0.0
            log("Volume updated for \(track.label): \(playerNode.volume)")
        }
    }
    
    private func stopPlayback() {
        pausePlayback()
        
        playerNodes.values.forEach { $0.stop() }
        audioEngine.stop()
        
        // Clean up temporary symlinks
        for url in tempURLs {
            try? FileManager.default.removeItem(at: url)
        }
        tempURLs = []
        playerNodes = [:]
        audioFiles = [:]
        
        isPlaying = false
    }
    private func commitCaptionEdit(trackID: UUID) {
        if let idx = tracks.firstIndex(where: { $0.id == trackID }) {
            tracks[idx].label = draftCaption
        }
        editingTrackID = nil
    }
    
    private func setupPlayers() {
        log("Setting up AVAudioEngine...")
        stopPlayback()
        
        let playableTracks = tracks.filter { !$0.isMissing && $0.url != nil }
        guard !playableTracks.isEmpty else {
            log("ERROR: No files to play")
            return
        }
        
        audioEngine = AVAudioEngine()
        subMixer = AVAudioMixerNode()
        timePitch = AVAudioUnitTimePitch()
        
        audioEngine.attach(subMixer)
        audioEngine.attach(timePitch)
        
        let mainMixer = audioEngine.mainMixerNode
        audioEngine.connect(subMixer, to: timePitch, format: nil)
        audioEngine.connect(timePitch, to: mainMixer, format: nil)
        
        var nodes: [UUID: AVAudioPlayerNode] = [:]
        var files: [UUID: AVAudioFile] = [:]
        var symlinks: [URL] = []
        
        let tempDir = FileManager.default.temporaryDirectory
        
        for track in playableTracks {
            guard let realURL = track.url else { continue }
            
            let ext = extensionForMimeType(track.mime)
            let tempName = "\(UUID().uuidString).\(ext)"
            let tempURL = tempDir.appendingPathComponent(tempName)
            
            do {
                try FileManager.default.createSymbolicLink(at: tempURL, withDestinationURL: realURL)
                symlinks.append(tempURL)
                
                let audioFile = try AVAudioFile(forReading: tempURL)
                files[track.id] = audioFile
                
                let playerNode = AVAudioPlayerNode()
                audioEngine.attach(playerNode)
                nodes[track.id] = playerNode
                
                audioEngine.connect(playerNode, to: subMixer, format: audioFile.processingFormat)
                playerNode.volume = track.isSelected ? 1.0 : 0.0
                
                log("Attached track: \(track.label)")
            } catch {
                log("ERROR loading track \(track.label): \(error.localizedDescription)")
            }
        }
        
        self.playerNodes = nodes
        self.audioFiles = files
        self.tempURLs = symlinks
        
        timePitch.rate = Float(playbackSpeed)
        
        do {
            try audioEngine.start()
            log("AVAudioEngine started successfully with \(nodes.count) nodes")
        } catch {
            log("ERROR starting AVAudioEngine: \(error.localizedDescription)")
        }
    }
    
    private func extensionForMimeType(_ mime: String?) -> String {
        guard let mime = mime else { return "m4a" }
        if mime.contains("audio/mpeg") || mime.contains("mp3") { return "mp3" }
        if mime.contains("wav") { return "wav" }
        if mime.contains("ogg") { return "ogg" }
        if mime.contains("aac") { return "aac" }
        if mime.contains("flac") { return "flac" }
        return "m4a"
    }
    
    private func cursorTimeToSeconds() -> Double {
        guard !tracks.isEmpty else { return 0 }
        let totalDur = tracks.map(\.duration).max() ?? 1.0
        let percent = Double(cursorPosition / contentWidth)
        let startOffset = currentTimeRange?.start.seconds ?? 0
        let displayDuration = currentTimeRange?.duration.seconds ?? totalDur
        return startOffset + (percent * displayDuration)
    }

    private func formatTime(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        let ms = Int((seconds.truncatingRemainder(dividingBy: 1)) * 100)
        return String(format: "%d:%02d.%02d", m, s, ms)
    }

    private func calculateX(for time: Double) -> CGFloat {
        guard !tracks.isEmpty else { return -1 }
        let totalDur = tracks.map(\.duration).max() ?? 1.0
        let startOffset = currentTimeRange?.start.seconds ?? 0
        let displayDuration = currentTimeRange?.duration.seconds ?? totalDur
        
        let relativeTime = time - startOffset
        if relativeTime < -0.1 || relativeTime > displayDuration + 0.1 { return -1 }
        
        return (CGFloat(relativeTime) / CGFloat(displayDuration)) * contentWidth
    }

    private func calculatePlayheadX() -> CGFloat {
        return calculateX(for: playbackTime)
    }

    private func handleZoomToSelection(startPct: Double, endPct: Double) {
        guard !tracks.isEmpty else { return }
        
        let leftPercent = Swift.min(startPct, endPct)
        let rightPercent = Swift.max(startPct, endPct)
        
        // Ensure minimum zoom distance (e.g. 1% of the view width)
        guard (rightPercent - leftPercent) > 0.01 else { return }
        
        let totalDur = tracks.map(\.duration).max() ?? 1.0
        let startOffset = currentTimeRange?.start.seconds ?? 0
        let displayDuration = currentTimeRange?.duration.seconds ?? totalDur
        
        let startSec = startOffset + (leftPercent * displayDuration)
        let endSec = startOffset + (rightPercent * displayDuration)
        
        let currentRange = currentTimeRange ?? CMTimeRange(start: .zero, duration: CMTime(seconds: totalDur, preferredTimescale: 600))
        zoomHistory.append(currentRange)
        
        let startCM = CMTime(seconds: startSec, preferredTimescale: 600)
        let durationCM = CMTime(seconds: endSec - startSec, preferredTimescale: 600)
        
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            self.currentTimeRange = CMTimeRange(start: startCM, duration: durationCM)
            self.zoomLevel = Double(self.zoomHistory.count)
        }
        
        self.loopStartPoint = startSec
        self.loopEndPoint = endSec
        
        seek(to: startSec)
    }

    private func refreshItem() async {
        log("Syncing item...")
        do {
            _ = try await store.getItem(id: item.id)
            log("Sync complete.")
        } catch {
            log("Sync error: \(error.localizedDescription)")
            errorMessage = "Sync Error: \(error.localizedDescription)"
        }
    }

    private func loadTracks() {
        log("Loading tracks...")
        errorMessage = nil
        
        struct TrackSource {
            let label: String
            let url: URL?
            let mime: String?
            let position: Int
            let isMissing: Bool
        }
        
        var sources: [TrackSource] = []
        let currentItem = store.items.first(where: { $0.id == item.id }) ?? item
        
        if let sp = currentItem.storePath {
            if let url = FilePathResolver.resolve(storePath: sp) {
                log("Master: \(currentItem.caption ?? "MASTER MIX")")
                sources.append(TrackSource(label: currentItem.caption ?? "MASTER MIX", url: url, mime: currentItem.mimeType, position: 0, isMissing: false))
            } else {
                log("Missing master: \(sp)")
                sources.append(TrackSource(label: currentItem.caption ?? "MASTER MIX", url: nil, mime: currentItem.mimeType, position: 0, isMissing: true))
            }
        }
        
        if let files = currentItem.files {
            for f in files {
                if let url = FilePathResolver.resolve(storePath: f.storePath) {
                    let caption = f.caption ?? "ATTACHED TRACK"
                    log("Track: \(caption)")
                    sources.append(TrackSource(label: caption, url: url, mime: f.mimeType, position: f.position, isMissing: false))
                } else {
                    let caption = f.caption ?? "ATTACHED TRACK"
                    log("Missing track: \(caption)")
                    sources.append(TrackSource(label: caption, url: nil, mime: f.mimeType, position: f.position, isMissing: true))
                }
            }
        }
        
        if sources.isEmpty {
            log("ERROR: No tracks")
            errorMessage = "No audio tracks found in local store."
            return
        }
        
        Task {
            await withTaskGroup(of: XRayTrack?.self) { group in
                for source in sources {
                    if source.isMissing {
                        group.addTask {
                            return XRayTrack(label: source.label, url: nil, mime: source.mime, duration: 0, samples: [], position: source.position, isMissing: true)
                        }
                    } else if let url = source.url {
                        group.addTask {
                            let track = await loadTrack(label: source.label, url: url, mime: source.mime)
                            if var t = track {
                                t.position = source.position
                                return t
                            }
                            return XRayTrack(label: source.label, url: nil, mime: source.mime, duration: 0, samples: [], position: source.position, isMissing: true)
                        }
                    }
                }
                
                var results: [XRayTrack] = []
                for await track in group {
                    if let track { results.append(track) }
                }
                
                let sorted = results.sorted { $0.position < $1.position }
                let final = sorted.map { t -> XRayTrack in
                    var track = t
                    if t.position == 0 { 
                        track.role = .master 
                    } else { 
                        track.role = .source 
                    }
                    let up = track.label.uppercased()
                    if up.contains("WATCH") { track.color = .orange }
                    else if up.contains("PHONE") { track.color = .blue }
                    else if track.role == .source { track.color = .cyan }
                    return track
                }
                
                await MainActor.run {
                    if final.isEmpty {
                        self.errorMessage = "Analysis failed for all tracks."
                    } else {
                        self.tracks = final
                        self.loadingStatus = ""
                        let totalDur = final.map(\.duration).max() ?? 0.0
                        self.totalFileDuration = totalDur
                        if self.loopEndPoint == nil || self.loopEndPoint == 0.0 {
                            self.loopStartPoint = 0.0
                            self.loopEndPoint = totalDur
                        }
                        setupPlayers()
                    }
                }
            }
        }
    }
    
    private func loadTrack(label: String, url: URL, mime: String?) async -> XRayTrack? {
        log("Extracting: \(label)")
        var opts: [String: Any]? = nil
        if let mime = mime { opts = ["AVURLAssetOutOfBandMIMETypeKey": mime] }
        
        let asset = AVURLAsset(url: url, options: opts)
        
        do {
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard let audioTrack = tracks.first else {
                log("No audio in \(label)")
                return nil
            }
            
            let samples = await WaveformGenerator.extractSamples(
                from: asset, 
                track: audioTrack, 
                count: 5000, 
                fullDuration: true,
                timeRange: nil // Always load full track samples for scrolling
            )
            
            let durObj = try? await asset.load(.duration)
            let fullDuration = durObj?.seconds ?? 0
            await MainActor.run { 
                if self.totalFileDuration == 0 {
                    self.totalFileDuration = fullDuration 
                }
            }
            
            log("Loaded: \(label)")
            
            return XRayTrack(label: label, url: url, mime: mime, duration: fullDuration, samples: samples, position: 0)
        } catch {
            log("Load error \(label): \(error.localizedDescription)")
            return nil
        }
    }
    
    private func runOptimizeMix() {
        stopPlayback()
        isOptimizing = true
        optimizingProgress = 0.0
        
        Task {
            do {
                // 1. Find the master track and all attached tracks
                guard let masterTrack = tracks.first(where: { $0.role == .master }),
                      let masterURL = masterTrack.url else {
                    throw NSError(domain: "XRayAudioView", code: 20, userInfo: [NSLocalizedDescriptionKey: "Master track is missing or not resolved"])
                }
                
                let masterMixInfo = AudioDSPAligner.TrackMixInfo(
                    url: masterURL,
                    isSelected: masterTrack.isSelected,
                    volume: masterTrack.volume
                )
                
                let sourceTracks = tracks.filter { $0.role == .source && !$0.isMissing && $0.url != nil }
                let sourceMixInfos = sourceTracks.map {
                    AudioDSPAligner.TrackMixInfo(
                        url: $0.url!,
                        isSelected: $0.isSelected,
                        volume: $0.volume
                    )
                }
                
                guard !sourceMixInfos.isEmpty else {
                    throw NSError(domain: "XRayAudioView", code: 21, userInfo: [NSLocalizedDescriptionKey: "No attached source tracks to align"])
                }
                
                log("Optimizing mix: \(sourceMixInfos.count) source tracks relative to master")
                
                // 2. Create a temporary output file path
                let tempDir = FileManager.default.temporaryDirectory
                let tempOutputURL = tempDir.appendingPathComponent("\(UUID().uuidString).m4a")
                
                // 3. Call AudioDSPAligner to align and mix
                try await AudioDSPAligner.alignAndMixTracks(
                    masterTrack: masterMixInfo,
                    sourceTracks: sourceMixInfos,
                    outputURL: tempOutputURL,
                    enhanceSpeech: enhanceSpeech,
                    progress: { progressValue in
                        Task { @MainActor in
                            self.optimizingProgress = progressValue
                        }
                    }
                )
                
                // 4. Overwrite the master track file on disk
                if FileManager.default.fileExists(atPath: masterURL.path) {
                    try FileManager.default.removeItem(at: masterURL)
                }
                try FileManager.default.moveItem(at: tempOutputURL, to: masterURL)
                
                log("Successfully optimized and wrote mixed track back to master file: \(masterURL.lastPathComponent)")
                
                // 5. Reload tracks to refresh waveforms and update duration
                await MainActor.run {
                    self.isOptimizing = false
                    self.loadTracks()
                }
            } catch {
                log("Optimize Mix failed: \(error.localizedDescription)")
                await MainActor.run {
                    self.isOptimizing = false
                    self.errorMessage = "Optimize Mix failed: \(error.localizedDescription)"
                }
            }
        }
    }
}

struct XRayTrack: Identifiable {
    enum Role { case master, source, composite }
    let id = UUID()
    var label: String
    let url: URL?
    let mime: String?
    let duration: Double
    let samples: [Float]
    var role: Role = .source
    var position: Int = 0
    var color: Color = .white
    var isMissing: Bool = false
    var isSelected: Bool = true
    var volume: Double = 1.0
}

private struct CompositeWaveformView: View {
    let composite: XRayTrack
    @Binding var tracks: [XRayTrack] 
    @Binding var cursorPosition: CGFloat
    let lensWidth: CGFloat
    let magnification: CGFloat
    @Binding var isHovering: Bool
    let contentWidth: CGFloat
    let currentTimeRange: CMTimeRange?
    
    @Binding var dragStart: CGPoint?
    @Binding var dragCurrent: CGPoint?
    @Binding var editingTrackID: UUID?
    @Binding var draftCaption: String
    let commitCaptionEdit: (UUID) -> Void
    let onSeekPercent: (Double) -> Void
    let onZoomEnded: (Double, Double) -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(composite.label)
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(Color.purple)
                Spacer()
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach($tracks) { $track in
                            legendItem(label: track.label, color: $track.color, trackID: track.id, isMaster: track.role == .master, isMissing: track.isMissing)
                        }
                    }
                    .padding(.horizontal, 4)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)
            let currentCursorPosition = cursorPosition
            let currentIsHovering = isHovering
            Canvas { context, size in
                let W = size.width
                let H = size.height
                if W <= 0 || H <= 0 { return }
                let midY = H / 2
                let xc = currentCursorPosition
                let wl = lensWidth
                let M = magnification
                let denominator = Double(W - wl) + (Double(wl) / Double(M))
                let k1 = 1.0 / (denominator > 0 ? denominator : 1.0)
                
                func xToTNorm(_ x: CGFloat) -> Double {
                    if !currentIsHovering || denominator <= 0 { return Double(Swift.max(0, Swift.min(W, x))) / Double(W) }
                    let xStart = xc - wl/2
                    let xEnd = xc + wl/2
                    if x < xStart { return Double(Swift.max(0, x)) * k1 }
                    else if x < xEnd { return Double(xStart) * k1 + Double(x - xStart) * (k1 / Double(M)) }
                    else { return Double(xStart) * k1 + Double(wl) * (k1 / Double(M)) + Double(Swift.min(W, x) - xEnd) * k1 }
                }
                
                let currentTracks = tracks
                guard let master = currentTracks.first(where: { $0.role == .master }), !master.isMissing else { return }
                let masterSamples = master.samples
                guard !masterSamples.isEmpty else { return }
                
                let sources = currentTracks.filter { $0.role == .source && !$0.isMissing }
                
                // 1. Calculate max amplitudes for normalization
                let masterMax = masterSamples.max() ?? 1.0
                let sourceMaxes = sources.map { $0.samples.max() ?? 1.0 }
                
                let totalDur = master.duration
                let startOffset = currentTimeRange?.start.seconds ?? 0
                let displayDuration = currentTimeRange?.duration.seconds ?? totalDur
                
                for x in stride(from: 0, to: W, by: 1) {
                    let tNorm = xToTNorm(x)
                    let currentSec = startOffset + (tNorm * displayDuration)
                    let mIdx = Swift.min(Swift.max(0, Int((currentSec / totalDur) * Double(masterSamples.count - 1))), masterSamples.count - 1)
                    let mVal = masterSamples[mIdx]
                    
                    if mVal < 0.01 { continue }
                    
                    let normalizedMaster = mVal / masterMax
                    var bestMatchColor: Color = master.color.opacity(0.3)
                    var minDiff: Float = 1.0
                    
                    for (idx, source) in sources.enumerated() {
                        let sSamples = source.samples
                        guard !sSamples.isEmpty else { continue }
                        let sIdx = Swift.min(Swift.max(0, Int((currentSec / totalDur) * Double(sSamples.count - 1))), sSamples.count - 1)
                        let normalizedSource = sSamples[sIdx] / sourceMaxes[idx]
                        
                        let diff = abs(normalizedSource - normalizedMaster)
                        if diff < minDiff {
                            minDiff = diff
                            if diff < 0.3 { // More inclusive threshold with normalized values
                                bestMatchColor = source.color
                            }
                        }
                    }
                    
                    let barH = CGFloat(mVal) * H * 0.8
                    let rect = CGRect(x: x, y: midY - (barH/2), width: 1, height: max(1, barH))
                    context.fill(Path(rect), with: .color(bestMatchColor.opacity(0.8)))
                }
                
                var topPath = Path()
                var bottomPath = Path()
                var first = true
                for x in stride(from: 0, to: W, by: 1) {
                    let tNorm = xToTNorm(x)
                    let currentSec = startOffset + (tNorm * displayDuration)
                    let val = masterSamples[Swift.min(Swift.max(0, Int((currentSec / totalDur) * Double(masterSamples.count - 1))), masterSamples.count - 1)]
                    let barH = CGFloat(val) * H * 0.8
                    let topPt = CGPoint(x: x, y: midY - (barH/2))
                    let botPt = CGPoint(x: x, y: midY + (barH/2))
                    if first { topPath.move(to: topPt); bottomPath.move(to: botPt); first = false }
                    else { topPath.addLine(to: topPt); bottomPath.addLine(to: botPt) }
                }
                context.stroke(topPath, with: .color(master.color), lineWidth: 0.5)
                context.stroke(bottomPath, with: .color(master.color), lineWidth: 0.5)
            }
            .background(Color.black.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.purple.opacity(0.3), lineWidth: 1)
            )
            .onTapGesture { location in
                guard contentWidth > 0 else { return }
                let percent = Double(location.x / contentWidth)
                onSeekPercent(percent)
            }
            .gesture(
                DragGesture(minimumDistance: 10)
                    .onChanged { value in
                        if dragStart == nil { dragStart = value.startLocation }
                        dragCurrent = value.location
                    }
                    .onEnded { value in
                        guard contentWidth > 0 else { return }
                        let startPct = Double(value.startLocation.x / contentWidth)
                        let endPct = Double(value.location.x / contentWidth)
                        onZoomEnded(startPct, endPct)
                        dragStart = nil
                        dragCurrent = nil
                    }
            )
        }
    }
    
    @State private var showingColorPopoverFor: UUID? = nil

    @ViewBuilder
    private func legendItem(label: String, color: Binding<Color>, trackID: UUID, isMaster: Bool, isMissing: Bool) -> some View {
        let colors: [Color] = [.white, .red, .orange, .yellow, .green, .mint, .teal, .cyan, .blue, .indigo, .purple, .pink, .brown]
        
        HStack(spacing: 4) {
            if isMissing {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
            } else {
                Circle()
                    .fill(color.wrappedValue)
                    .frame(width: 12, height: 12)
                    .contentShape(Rectangle())
                    .onTapGesture { showingColorPopoverFor = trackID }
                    .popover(isPresented: Binding(
                        get: { showingColorPopoverFor == trackID },
                        set: { if !$0 && showingColorPopoverFor == trackID { showingColorPopoverFor = nil } }
                    )) {
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(20), spacing: 8), count: 4), spacing: 8) {
                            ForEach(colors, id: \.self) { c in
                                Circle()
                                    .fill(c)
                                    .frame(width: 20, height: 20)
                                    .overlay(Circle().stroke(Color.primary, lineWidth: color.wrappedValue == c ? 2 : 0))
                                    .onTapGesture { 
                                        color.wrappedValue = c 
                                        showingColorPopoverFor = nil
                                    }
                            }
                        }
                        .padding(12)
                    }
            }
            Text(label.uppercased())
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(isMissing ? .secondary : color.wrappedValue)
                .strikethrough(isMissing)
                .onTapGesture(count: 2) {
                    if !isMaster {
                        draftCaption = label
                        editingTrackID = trackID
                    }
                }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 6)
        .background(Color.black.opacity(0.3))
        .clipShape(Capsule())
    }
}

private struct WaveformTrackView: View {
    @Binding var track: XRayTrack
    @Binding var cursorPosition: CGFloat
    let lensWidth: CGFloat
    let magnification: CGFloat
    @Binding var isHovering: Bool
    let contentWidth: CGFloat
    let currentTimeRange: CMTimeRange?
    
    @Binding var dragStart: CGPoint?
    @Binding var dragCurrent: CGPoint?
    let onSeekPercent: (Double) -> Void
    let onZoomEnded: (Double, Double) -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Toggle("", isOn: $track.isSelected)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .controlSize(.small)
                
                Text(track.label)
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(track.isMissing ? .secondary : track.color)
                if !track.isMissing {
                    HStack(spacing: 4) {
                        Image(systemName: track.isSelected ? (track.volume > 0.5 ? "speaker.wave.2.fill" : "speaker.wave.1.fill") : "speaker.slash.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .frame(width: 14)
                            .onTapGesture {
                                track.isSelected.toggle()
                            }
                        
                        Slider(value: $track.volume, in: 0.0...1.0)
                            .controlSize(.mini)
                            .frame(width: 60)
                            .disabled(!track.isSelected)
                    }
                    .padding(.trailing, 12)
                }
                
                Spacer()
                
                if track.isMissing {
                    Text("FILE MISSING")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.red)
                } else {
                    Text(formatTime(track.duration))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)
            
            if track.isMissing {
                Rectangle()
                    .fill(Color.black.opacity(0.2))
                    .frame(height: 140)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(
                        Text("Not available in local store")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    )
            } else {
                let currentCursorPosition = cursorPosition
                let currentIsHovering = isHovering
                Canvas(rendersAsynchronously: true) { context, size in
                    let W = size.width.isFinite ? Swift.min(size.width, 10000) : 10000
                    let H = size.height.isFinite ? Swift.min(size.height, 10000) : 10000
                    if W <= 0 || H <= 0 { return }
                    let midY = H / 2
                    let xc = currentCursorPosition
                    let wl = lensWidth
                    let M = magnification
                    let denominator = Double(W - wl) + (Double(wl) / Double(M))
                    let k1 = 1.0 / (denominator > 0 ? denominator : 1.0)
                    
                    func xToTNorm(_ x: CGFloat) -> Double {
                        if !currentIsHovering || denominator <= 0 { return Double(Swift.max(0, Swift.min(W, x))) / Double(W) }
                        let xStart = xc - wl/2
                        let xEnd = xc + wl/2
                        if x < xStart { return Double(Swift.max(0, x)) * k1 }
                        else if x < xEnd { return Double(xStart) * k1 + Double(x - xStart) * (k1 / Double(M)) }
                        else { return Double(xStart) * k1 + Double(wl) * (k1 / Double(M)) + Double(Swift.min(W, x) - xEnd) * k1 }
                    }
                    
                    let totalDur = track.duration
                    let startOffset = currentTimeRange?.start.seconds ?? 0
                    let displayDuration = currentTimeRange?.duration.seconds ?? totalDur
                    
                    let samples = track.samples
                    guard !samples.isEmpty else { return }
                    var insideRects: [CGRect] = []
                    var outsideRects: [CGRect] = []
                    for x in stride(from: 0, to: W, by: 1) {
                        let tNorm = xToTNorm(x)
                        let currentSec = startOffset + (tNorm * displayDuration)
                        let sampleIndex = Int((currentSec / totalDur) * Double(samples.count - 1))
                        let sample = samples[Swift.min(Swift.max(0, sampleIndex), samples.count - 1)]
                        let barHeight = CGFloat(sample) * H * 0.7
                        let rect = CGRect(x: x, y: midY - (barHeight / 2), width: 1, height: max(1, barHeight))
                        let isInLens = currentIsHovering && abs(x - xc) < wl/2
                        if isInLens {
                            insideRects.append(rect)
                        } else {
                            outsideRects.append(rect)
                        }
                    }
                    var insidePath = Path()
                    insidePath.addRects(insideRects)
                    context.fill(insidePath, with: .color(track.color))
                    
                    var outsidePath = Path()
                    outsidePath.addRects(outsideRects)
                    context.fill(outsidePath, with: .color(track.color.opacity(0.4)))
                }
                .background(Color.black.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .onTapGesture { location in
                    guard contentWidth > 0 else { return }
                    let percent = Double(location.x / contentWidth)
                    onSeekPercent(percent)
                }
                .gesture(
                    DragGesture(minimumDistance: 10)
                        .onChanged { value in
                            if dragStart == nil { dragStart = value.startLocation }
                            dragCurrent = value.location
                        }
                        .onEnded { value in
                            guard contentWidth > 0 else { return }
                            let startPct = Double(value.startLocation.x / contentWidth)
                            let endPct = Double(value.location.x / contentWidth)
                            onZoomEnded(startPct, endPct)
                            dragStart = nil
                            dragCurrent = nil
                        }
                )
            }
        }
    }
    
    private func formatTime(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }
}

private struct TimelineRulerView: View {
    let contentWidth: CGFloat
    let currentTimeRange: CMTimeRange?
    let totalDuration: Double
    @Binding var cursorPosition: CGFloat
    @Binding var isHovering: Bool
    let onSeekPercent: (Double) -> Void
    
    var body: some View {
        let rulerWidth = contentWidth - 16
        Canvas(rendersAsynchronously: true) { context, size in
            let W = size.width.isFinite ? Swift.min(size.width, 10000) : 10000
            let H = size.height.isFinite ? Swift.min(size.height, 10000) : 10000
            if W <= 0 || H <= 0 { return }
            
            let startOffset = currentTimeRange?.start.seconds ?? 0
            let displayDuration = currentTimeRange?.duration.seconds ?? totalDuration
            
            // Draw horizontal baseline
            context.stroke(Path { p in
                p.move(to: CGPoint(x: 0, y: H - 1))
                p.addLine(to: CGPoint(x: W, y: H - 1))
            }, with: .color(.secondary.opacity(0.3)), lineWidth: 1)
            
            // Decide tick intervals based on displayDuration
            let tickInterval: Double
            if displayDuration < 2.0 {
                tickInterval = 0.2 // 200ms
            } else if displayDuration < 5.0 {
                tickInterval = 0.5 // 500ms
            } else if displayDuration < 20.0 {
                tickInterval = 2.0 // 2s
            } else if displayDuration < 60.0 {
                tickInterval = 5.0 // 5s
            } else if displayDuration < 300.0 {
                tickInterval = 10.0 // 10s
            } else {
                tickInterval = 30.0 // 30s
            }
            
            let firstTick = ceil(startOffset / tickInterval) * tickInterval
            var currentTick = firstTick
            var tickCount = 0
            
            while currentTick <= startOffset + displayDuration && tickCount < 1000 {
                let percent = (currentTick - startOffset) / displayDuration
                let x = CGFloat(percent) * W
                
                // Draw tick line
                context.stroke(Path { p in
                    p.move(to: CGPoint(x: x, y: H - 8))
                    p.addLine(to: CGPoint(x: x, y: H - 1))
                }, with: .color(.secondary.opacity(0.5)), lineWidth: 1)
                
                // Draw tick label
                let minutes = Int(currentTick) / 60
                let seconds = Int(currentTick) % 60
                let ms = Int((currentTick.truncatingRemainder(dividingBy: 1)) * 10)
                let labelStr: String
                if tickInterval < 1.0 {
                    labelStr = String(format: "%d:%02d.%d", minutes, seconds, ms)
                } else {
                    labelStr = String(format: "%d:%02d", minutes, seconds)
                }
                
                let text = Text(labelStr)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.secondary)
                
                let resolved = context.resolve(text)
                context.draw(resolved, at: CGPoint(x: x, y: H - 12), anchor: .bottom)
                
                currentTick += tickInterval
                tickCount += 1
            }
        }
        .frame(height: 28)
        .contentShape(Rectangle())
        .onTapGesture { location in
            guard rulerWidth > 0 else { return }
            let percent = Double(location.x / rulerWidth)
            onSeekPercent(percent)
        }
    }
}

extension Array {
    subscript(clamped index: Int) -> Element {
        guard !isEmpty else { fatalError("Array is empty") }
        return self[Swift.min(Swift.max(0, index), count - 1)]
    }
}

private struct SelectionHighlightOverlay: View {
    @Binding var dragStart: CGPoint?
    @Binding var dragCurrent: CGPoint?
    
    var body: some View {
        let hlStart = dragStart?.x ?? 0
        let hlCurrent = dragCurrent?.x ?? 0
        let isHighlighting = dragStart != nil && dragCurrent != nil
        Rectangle()
            .fill(Color.blue.opacity(0.3))
            .frame(width: isHighlighting ? abs(hlCurrent - hlStart) : 0)
            .offset(x: Swift.min(hlStart, hlCurrent))
            .allowsHitTesting(false)
    }
}

private struct HoverCursorOverlay: View {
    @Binding var cursorPosition: CGFloat
    @Binding var isHovering: Bool
    @Binding var dragStart: CGPoint?
    let contentWidth: CGFloat
    let tracks: [XRayTrack]
    let currentTimeRange: CMTimeRange?
    
    private func cursorTimeToSeconds() -> Double {
        guard !tracks.isEmpty, contentWidth > 0 else { return 0 }
        let totalDur = tracks.map(\.duration).max() ?? 1.0
        let percent = Double(cursorPosition / contentWidth)
        let startOffset = currentTimeRange?.start.seconds ?? 0
        let displayDuration = currentTimeRange?.duration.seconds ?? totalDur
        return startOffset + (percent * displayDuration)
    }
    
    private func formatTime(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }
    
    var body: some View {
        let time = cursorTimeToSeconds()
        let showCursor = isHovering && dragStart == nil
        Rectangle()
            .fill(Color.accentColor)
            .frame(width: 1.5)
            .overlay(
                Text(formatTime(time))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
                    .shadow(radius: 3)
                    .frame(width: 60)
                    .offset(y: -12),
                alignment: .bottom
            )
            .offset(x: cursorPosition)
            .allowsHitTesting(false)
            .zIndex(500)
            .opacity(showCursor ? 1 : 0)
    }
}
