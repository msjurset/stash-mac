import SwiftUI
import AVFoundation

/// A multi-track waveform visualizer with dynamic "Lens" magnification,
/// recursive zooming, and synchronized multi-track playback.
struct XRayAudioView: View {
    let item: StashItem
    let onDismiss: () -> Void

    @State private var tracks: [XRayTrack] = []
    @State private var cursorPosition: CGFloat = 0 
    @State private var isHovering = false
    @State private var zoomLevel: Double = 0 
    @State private var containerWidth: CGFloat = 800
    @State private var loadingStatus: String = "Initializing analyzer..."
    @State private var diagnosticLog: [LogEntry] = []
    @State private var errorMessage: String? = nil
    
    // Selection/Crop State
    @State private var dragStart: CGPoint? = nil
    @State private var dragCurrent: CGPoint? = nil
    @State private var currentTimeRange: CMTimeRange? = nil
    
    // Playback State
    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var playbackTime: Double = 0 
    @State private var playbackSpeed: Double = 1.0
    @State private var isLooping = true
    @State private var timeObserver: Any?
    @State private var totalFileDuration: Double = 0
    
    struct LogEntry: Identifiable {
        let id = UUID()
        let timestamp = Date()
        let message: String
        var display: String {
            "\(timestamp.formatted(.dateTime.hour().minute().second())): \(message)"
        }
    }
    
    private let lensWidth: CGFloat = 200
    private let magnification: CGFloat = 6.0
    
    private func log(_ msg: String) {
        print("[X-RAY] \(msg)")
        diagnosticLog.append(LogEntry(message: msg))
    }

    var body: some View {
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
                    
                    Button("Retry") {
                        errorMessage = nil
                        loadTracks()
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if tracks.isEmpty {
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text(loadingStatus)
                        .font(.headline)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(diagnosticLog.suffix(5)) { entry in
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
                ScrollViewReader { scrollProxy in
                    ScrollView(.horizontal) {
                        ZStack(alignment: .leading) {
                            VStack(spacing: 12) {
                                // 1. Composite Layer with Interactive Legend
                                if let composite = createCompositeTrack() {
                                    CompositeWaveformView(
                                        composite: composite,
                                        tracks: $tracks,
                                        master: tracks.first { $0.role == .master },
                                        cursorPosition: cursorPosition,
                                        lensWidth: lensWidth,
                                        magnification: magnification,
                                        isHovering: isHovering,
                                        contentWidth: contentWidth
                                    )
                                    .frame(width: contentWidth)
                                }
                                
                                Divider().background(Color.white.opacity(0.1))
                                
                                // 2. Individual Tracks
                                ForEach(tracks) { track in
                                    WaveformTrackView(
                                        track: track,
                                        cursorPosition: cursorPosition,
                                        lensWidth: lensWidth,
                                        magnification: magnification,
                                        isHovering: isHovering,
                                        contentWidth: contentWidth
                                    )
                                    .frame(width: contentWidth)
                                }
                            }
                            .padding(.vertical, 8)
                            
                            // Playhead Overlay
                            let playheadX = calculatePlayheadX()
                            if playheadX >= 0 && playheadX <= contentWidth {
                                Rectangle()
                                    .fill(Color.yellow)
                                    .frame(width: 2)
                                    .offset(x: playheadX)
                                    .shadow(color: .black.opacity(0.5), radius: 2)
                                    .zIndex(10)
                            }
                            
                            // Selection Highlight
                            if let start = dragStart, let current = dragCurrent {
                                let x1 = start.x
                                let x2 = current.x
                                Rectangle()
                                    .fill(Color.blue.opacity(0.3))
                                    .frame(width: abs(x2 - x1))
                                    .offset(x: min(x1, x2))
                            }
                            
                            // Vertical Cursor Line (Hover)
                            if isHovering && dragStart == nil {
                                Rectangle()
                                    .fill(Color.accentColor.opacity(0.5))
                                    .frame(width: 1)
                                    .offset(x: cursorPosition)
                            }
                        }
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                cursorPosition = location.x
                                isHovering = true
                            case .ended:
                                isHovering = false
                            }
                        }
                        .gesture(
                            DragGesture(minimumDistance: 5)
                                .onChanged { value in
                                    if dragStart == nil { dragStart = value.startLocation }
                                    dragCurrent = value.location
                                }
                                .onEnded { value in
                                    handleCrop(start: value.startLocation, end: value.location)
                                    dragStart = nil
                                    dragCurrent = nil
                                }
                        )
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
        .onAppear {
            loadTracks()
        }
        .onDisappear {
            stopPlayback()
        }
    }
    
    private var contentWidth: CGFloat {
        let clampedZoom = max(0, min(zoomLevel, 10))
        return containerWidth * pow(magnification, clampedZoom)
    }
    
    private var header: some View {
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
            }
            
            Spacer()
            
            // Playback Controls
            HStack(spacing: 12) {
                Button(action: { isLooping.toggle() }) {
                    Image(systemName: isLooping ? "repeat.1" : "repeat")
                        .foregroundStyle(isLooping ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help("Toggle Loop")

                Menu {
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { speed in
                        Button("\(speed, specifier: "%.2f")x") {
                            playbackSpeed = speed
                            if isPlaying { player?.rate = Float(speed) }
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
                .frame(width: 40)

                Button(action: togglePlayback) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 24)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.2))
            .clipShape(Capsule())
            
            Spacer()
            
            if currentTimeRange != nil {
                Button("Clear Crop") {
                    currentTimeRange = nil
                    tracks = []
                    loadTracks()
                }
                .controlSize(.small)
            }
            
            if zoomLevel > 0 {
                Button("Reset Zoom") {
                    if zoomLevel > 3 { zoomLevel = 0 }
                    else { withAnimation { zoomLevel = 0 } }
                }
                .controlSize(.small)
            }
            
            Button(action: { if zoomLevel > 0 { withAnimation { zoomLevel -= 1 } } }) {
                Label("Back", systemImage: "arrow.uturn.backward")
            }
            .disabled(zoomLevel == 0)
            .controlSize(.small)
        }
        .padding()
        .background(.bar)
    }
    
    private func createCompositeTrack() -> XRayTrack? {
        guard !tracks.isEmpty else { return nil }
        return XRayTrack(
            label: "COMPOSITE X-RAY",
            url: nil,
            duration: tracks.map(\.duration).max() ?? 0,
            samples: [], 
            role: .composite,
            position: -1
        )
    }

    private func togglePlayback() {
        if isPlaying {
            player?.pause()
            isPlaying = false
        } else {
            startPlayback()
        }
    }
    
    private func startPlayback() {
        if player == nil { setupPlayer() }
        guard let player = player else { return }
        
        let startTime = currentTimeRange?.start ?? .zero
        let endTime = currentTimeRange?.end ?? .indefinite
        
        let current = player.currentTime()
        if current >= endTime || current < startTime {
            player.seek(to: startTime, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        
        player.rate = Float(playbackSpeed)
        player.play()
        isPlaying = true
    }
    
    private func stopPlayback() {
        player?.pause()
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        player = nil
        isPlaying = false
    }
    
    private func setupPlayer() {
        guard let masterURL = tracks.first(where: { $0.role == .master })?.url else { return }
        let asset = AVURLAsset(url: masterURL)
        let item = AVPlayerItem(asset: asset)
        let newPlayer = AVPlayer(playerItem: item)
        
        timeObserver = newPlayer.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 60), queue: .main) { [weak newPlayer] time in
            guard let player = newPlayer else { return }
            
            Task { @MainActor in
                self.playbackTime = time.seconds
                
                let endTime = self.currentTimeRange?.end ?? CMTime(seconds: self.totalFileDuration, preferredTimescale: 600)
                if time >= endTime {
                    if self.isLooping {
                        player.seek(to: self.currentTimeRange?.start ?? .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                        player.play()
                    } else {
                        player.pause()
                        self.isPlaying = false
                    }
                }
            }
        }
        
        self.player = newPlayer
    }
    
    private func calculatePlayheadX() -> CGFloat {
        guard !tracks.isEmpty else { return -1 }
        let totalDisplayDuration = tracks[0].duration 
        let startOffset = currentTimeRange?.start.seconds ?? 0
        
        let relativeTime = playbackTime - startOffset
        if relativeTime < 0 || relativeTime > totalDisplayDuration + 0.1 { return -1 }
        
        return (CGFloat(relativeTime) / CGFloat(totalDisplayDuration)) * contentWidth
    }

    private func handleCrop(start: CGPoint, end: CGPoint) {
        guard !tracks.isEmpty else { return }
        let W = contentWidth
        let totalDur = tracks.map(\.duration).max() ?? 1.0
        
        func xToT(_ x: CGFloat) -> Double {
            return Double(max(0, min(W, x)) / W) * totalDur
        }
        
        let t1 = xToT(start.x)
        let t2 = xToT(end.x)
        
        let startT = min(t1, t2)
        let endT = max(t1, t2)
        let dur = endT - startT
        
        guard dur > 0.1 else { return } 
        
        let absoluteStartOffset = currentTimeRange?.start.seconds ?? 0
        let absStart = absoluteStartOffset + startT
        let absEnd = absoluteStartOffset + endT
        
        let range = CMTimeRange(
            start: CMTime(seconds: absStart, preferredTimescale: 600),
            duration: CMTime(seconds: dur, preferredTimescale: 600)
        )
        
        log("Cropping to range: \(String(format: "%.2fs - %.2fs", absStart, absEnd))")
        self.currentTimeRange = range
        self.zoomLevel = 0 
        self.tracks = [] 
        stopPlayback() 
        loadTracks()
    }

    private func loadTracks() {
        log("Identifying tracks for item \(item.shortID)")
        errorMessage = nil
        
        struct TrackSource {
            let label: String
            let url: URL
            let mime: String?
            let position: Int
        }
        
        var sources: [TrackSource] = []
        if let sp = item.storePath, let url = FilePathResolver.resolve(storePath: sp) {
            sources.append(TrackSource(label: item.caption ?? "MASTER MIX", url: url, mime: item.mimeType, position: 0))
        }
        
        if let files = item.files {
            for f in files {
                if let url = FilePathResolver.resolve(storePath: f.storePath) {
                    let caption = f.caption ?? "ATTACHED TRACK"
                    sources.append(TrackSource(label: caption, url: url, mime: f.mimeType, position: f.position))
                }
            }
        }
        
        Task {
            await withTaskGroup(of: XRayTrack?.self) { group in
                for source in sources {
                    group.addTask {
                        let track = await loadTrack(label: source.label, url: source.url, mime: source.mime)
                        if var t = track {
                            t.position = source.position
                            return t
                        }
                        return nil
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
                        self.errorMessage = "Could not analyze any audio tracks."
                    } else {
                        self.tracks = final
                        self.loadingStatus = ""
                        setupPlayer()
                    }
                }
            }
        }
    }
    
    private func loadTrack(label: String, url: URL, mime: String?) async -> XRayTrack? {
        var opts: [String: Any]? = nil
        if let mime = mime { opts = ["AVURLAssetOutOfBandMIMETypeKey": mime] }
        
        let asset = AVURLAsset(url: url, options: opts)
        guard let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first else {
            return nil
        }
        
        let samples = await WaveformGenerator.extractSamples(
            from: asset, 
            track: audioTrack, 
            count: 5000, 
            fullDuration: true,
            timeRange: currentTimeRange
        )
        
        let durObj = try? await asset.load(.duration)
        let fullDuration = durObj?.seconds ?? 0
        await MainActor.run { self.totalFileDuration = fullDuration }
        
        let duration = currentTimeRange?.duration.seconds ?? fullDuration
        
        return XRayTrack(label: label, url: url, duration: duration, samples: samples, position: 0)
    }
}

struct XRayTrack: Identifiable {
    enum Role { case master, source, composite }
    let id = UUID()
    var label: String
    let url: URL?
    let duration: Double
    let samples: [Float]
    var role: Role = .source
    var position: Int = 0
    var color: Color = .white
}

private struct CompositeWaveformView: View {
    let composite: XRayTrack
    @Binding var tracks: [XRayTrack] // Renamed to tracks to avoid confusion
    let master: XRayTrack?
    let cursorPosition: CGFloat
    let lensWidth: CGFloat
    let magnification: CGFloat
    let isHovering: Bool
    let contentWidth: CGFloat
    
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(composite.label)
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(Color.purple)
                Spacer()
                
                HStack(spacing: 12) {
                    if let m = master {
                        legendItem(label: m.label, color: .constant(.white), isMaster: true)
                    }
                    ForEach($tracks) { $track in
                        if track.role == .source {
                            legendItem(label: track.label, color: $track.color, isMaster: false)
                        }
                    }
                }
                .font(.system(size: 9, weight: .bold))
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)
            
            Canvas { context, size in
                let W = size.width
                let H = size.height
                if W <= 0 || H <= 0 { return }
                let midY = H / 2
                let xc = cursorPosition
                let wl = lensWidth
                let M = magnification
                let denominator = Double(W - wl) + (Double(wl) / Double(M))
                let k1 = 1.0 / (denominator > 0 ? denominator : 1.0)
                
                func xToTNorm(_ x: CGFloat) -> Double {
                    if !isHovering || denominator <= 0 { return Double(Swift.max(0, Swift.min(W, x))) / Double(W) }
                    let xStart = xc - wl/2
                    let xEnd = xc + wl/2
                    if x < xStart { return Double(Swift.max(0, x)) * k1 }
                    else if x < xEnd { return Double(xStart) * k1 + Double(x - xStart) * (k1 / Double(M)) }
                    else { return Double(xStart) * k1 + Double(wl) * (k1 / Double(M)) + Double(Swift.min(W, x) - xEnd) * k1 }
                }
                
                // Use a local copy of the array for drawing to avoid Binding capture issues
                let currentTracks = tracks
                
                // Draw sources (Thin 1px bars with "Used" glow)
                for source in currentTracks where source.role == .source {
                    let samples = source.samples
                    guard !samples.isEmpty else { continue }
                    
                    for x in stride(from: 0, to: W, by: 1) {
                        let tNorm = xToTNorm(x)
                        let sVal = samples[Swift.min(Swift.max(0, Int(tNorm * Double(samples.count - 1))), samples.count - 1)]
                        
                        let barH = CGFloat(sVal) * H * 0.7
                        let rect = CGRect(x: x, y: midY - (barH/2), width: 1, height: max(1, barH))
                        
                        var masterVal: Float = 0
                        if let master = master {
                            let ms = master.samples
                            if !ms.isEmpty {
                                masterVal = ms[Swift.min(Swift.max(0, Int(tNorm * Double(ms.count - 1))), ms.count - 1)]
                            }
                        }
                        
                        let isUsed = abs(sVal - masterVal) < 0.15
                        context.fill(Path(rect), with: .color(source.color.opacity(isUsed ? 0.9 : 0.25)))
                    }
                }
                
                if let master = master, !master.samples.isEmpty {
                    var topPath = Path()
                    var bottomPath = Path()
                    var first = true
                    let ms = master.samples
                    for x in stride(from: 0, to: W, by: 1) {
                        let tNorm = xToTNorm(x)
                        let val = ms[Swift.min(Swift.max(0, Int(tNorm * Double(ms.count - 1))), ms.count - 1)]
                        let barH = CGFloat(val) * H * 0.7
                        let topPt = CGPoint(x: x, y: midY - (barH/2))
                        let botPt = CGPoint(x: x, y: midY + (barH/2))
                        if first { topPath.move(to: topPt); bottomPath.move(to: botPt); first = false }
                        else { topPath.addLine(to: topPt); bottomPath.addLine(to: botPt) }
                    }
                    context.stroke(topPath, with: .color(.white), lineWidth: 1.0)
                    context.stroke(bottomPath, with: .color(.white), lineWidth: 1.0)
                }
            }
            .background(Color.black.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.purple.opacity(0.3), lineWidth: 1)
            )
        }
        .frame(height: 180)
    }
    
    @State private var showingColorPopoverFor: String? = nil

    @ViewBuilder
    private func legendItem(label: String, color: Binding<Color>, isMaster: Bool) -> some View {
        HStack(spacing: 4) {
            if isMaster {
                Image(systemName: "circle.fill")
                    .foregroundStyle(.white)
            } else {
                Circle()
                    .fill(color.wrappedValue)
                    .frame(width: 12, height: 12)
                    .contentShape(Rectangle())
                    .onTapGesture { showingColorPopoverFor = label }
                    .popover(isPresented: Binding(
                        get: { showingColorPopoverFor == label },
                        set: { if !$0 && showingColorPopoverFor == label { showingColorPopoverFor = nil } }
                    )) {
                        let colors: [Color] = [.red, .orange, .yellow, .green, .mint, .teal, .cyan, .blue, .indigo, .purple, .pink, .brown]
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(20), spacing: 8), count: 4), spacing: 8) {
                            ForEach(colors, id: \.self) { c in
                                Circle()
                                    .fill(c)
                                    .frame(width: 20, height: 20)
                                    .overlay(Circle().stroke(Color.primary, lineWidth: color.wrappedValue == c ? 2 : 0))
                                    .onTapGesture { color.wrappedValue = c }
                            }
                        }
                        .padding(12)
                    }
            }
            Text(label.uppercased())
                .foregroundStyle(isMaster ? .white : color.wrappedValue)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 6)
        .background(Color.black.opacity(0.3))
        .clipShape(Capsule())
    }
}

private struct WaveformTrackView: View {
    let track: XRayTrack
    let cursorPosition: CGFloat
    let lensWidth: CGFloat
    let magnification: CGFloat
    let isHovering: Bool
    let contentWidth: CGFloat
    
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(track.label)
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(track.color)
                Spacer()
                Text(formatTime(track.duration))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)
            
            Canvas { context, size in
                let W = size.width
                let H = size.height
                if W <= 0 || H <= 0 { return }
                let midY = H / 2
                let xc = cursorPosition
                let wl = lensWidth
                let M = magnification
                let denominator = Double(W - wl) + (Double(wl) / Double(M))
                let k1 = 1.0 / (denominator > 0 ? denominator : 1.0)
                
                func xToTNorm(_ x: CGFloat) -> Double {
                    if !isHovering || denominator <= 0 { return Double(Swift.max(0, Swift.min(W, x))) / Double(W) }
                    let xStart = xc - wl/2
                    let xEnd = xc + wl/2
                    if x < xStart { return Double(Swift.max(0, x)) * k1 }
                    else if x < xEnd { return Double(xStart) * k1 + Double(x - xStart) * (k1 / Double(M)) }
                    else { return Double(xStart) * k1 + Double(wl) * (k1 / Double(M)) + Double(Swift.min(W, x) - xEnd) * k1 }
                }
                
                let samples = track.samples
                guard !samples.isEmpty else { return }
                for x in stride(from: 0, to: W, by: 1) {
                    let tNorm = xToTNorm(x)
                    let sampleIndex = Int(tNorm * Double(samples.count - 1))
                    let sample = samples[Swift.min(Swift.max(0, sampleIndex), samples.count - 1)]
                    let barHeight = CGFloat(sample) * H * 0.7
                    let rect = CGRect(x: x, y: midY - (barHeight / 2), width: 1, height: max(1, barHeight))
                    let isInLens = isHovering && abs(x - xc) < wl/2
                    context.fill(Path(rect), with: .color(isInLens ? track.color : track.color.opacity(0.4)))
                }
            }
            .background(Color.black.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .frame(height: 140)
    }
    
    private func formatTime(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }
}

extension Array {
    subscript(clamped index: Int) -> Element {
        guard !isEmpty else { fatalError("Array is empty") }
        return self[Swift.min(Swift.max(0, index), count - 1)]
    }
}
