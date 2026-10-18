import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import StashMac

// MARK: - Annotation Canvas Models

struct DocCallout: Identifiable {
    let number: Int
    let title: String
    let subtitle: String
    let targetRect: CGRect
    let badgeCenter: CGPoint
    let color: Color

    var id: Int { number }

    var arrowTarget: CGPoint {
        let minX = targetRect.minX
        let maxX = targetRect.maxX
        let minY = targetRect.minY
        let maxY = targetRect.maxY

        let clampedX = min(max(badgeCenter.x, minX), maxX)
        let clampedY = min(max(badgeCenter.y, minY), maxY)

        if clampedX != badgeCenter.x || clampedY != badgeCenter.y {
            return CGPoint(x: clampedX, y: clampedY)
        }
        return CGPoint(x: targetRect.midX, y: targetRect.midY)
    }

    var estimatedBadgeRect: CGRect {
        let width = CGFloat(max(title.count, subtitle.count)) * 6.8 + 56.0
        let badgeWidth = min(max(width, 195.0), 295.0)
        let badgeHeight: CGFloat = 46.0
        return CGRect(
            x: badgeCenter.x - badgeWidth / 2.0,
            y: badgeCenter.y - badgeHeight / 2.0,
            width: badgeWidth,
            height: badgeHeight
        )
    }
}

struct AnnotatedScreenshotCanvas<Content: View>: View {
    let content: Content
    let size: CGSize
    let callouts: [DocCallout]

    init(size: CGSize, callouts: [DocCallout], @ViewBuilder content: () -> Content) {
        self.size = size
        self.callouts = callouts
        self.content = content()
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            content
                .frame(width: size.width, height: size.height)
                .background(Color(NSColor.windowBackgroundColor))
                .environment(\.colorScheme, .dark)
                .clipped()

            // Highlight target rectangles (strictly zero interior fill shading)
            ForEach(callouts) { callout in
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(Color.black.opacity(0.65), lineWidth: 4.0)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(callout.color, lineWidth: 2.2)
                    )
                    .frame(width: callout.targetRect.width, height: callout.targetRect.height)
                    .position(x: callout.targetRect.midX, y: callout.targetRect.midY)
            }

            // Connector lines + arrowheads
            Canvas { context, _ in
                for callout in callouts {
                    let from = callout.badgeCenter
                    let to = callout.arrowTarget

                    var line = Path()
                    line.move(to: from)
                    line.addLine(to: to)

                    context.stroke(
                        line,
                        with: .color(Color.black.opacity(0.65)),
                        style: StrokeStyle(lineWidth: 4.2, lineCap: .round)
                    )
                    context.stroke(
                        line,
                        with: .color(callout.color),
                        style: StrokeStyle(lineWidth: 2.2, lineCap: .round)
                    )

                    let angle = atan2(to.y - from.y, to.x - from.x)
                    let arrowLen: CGFloat = 10
                    let arrowAngle: CGFloat = .pi / 6

                    var arrow = Path()
                    arrow.move(to: to)
                    arrow.addLine(to: CGPoint(
                        x: to.x - arrowLen * cos(angle - arrowAngle),
                        y: to.y - arrowLen * sin(angle - arrowAngle)
                    ))
                    arrow.addLine(to: CGPoint(
                        x: to.x - arrowLen * cos(angle + arrowAngle),
                        y: to.y - arrowLen * sin(angle + arrowAngle)
                    ))
                    arrow.closeSubpath()

                    context.fill(arrow, with: .color(callout.color))
                }
            }
            .frame(width: size.width, height: size.height)
            .allowsHitTesting(false)

            // Callout pill cards
            ForEach(callouts) { callout in
                HStack(spacing: 8) {
                    Text("\(callout.number)")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(callout.color))

                    VStack(alignment: .leading, spacing: 1) {
                        Text(callout.title)
                            .font(.system(size: 11.5, weight: .bold))
                            .foregroundStyle(.white)
                        Text(callout.subtitle)
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.82))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(Color(red: 0.09, green: 0.10, blue: 0.14).opacity(0.95))
                        .shadow(color: Color.black.opacity(0.45), radius: 8, x: 0, y: 4)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(callout.color.opacity(0.9), lineWidth: 1.5)
                )
                .position(callout.badgeCenter)
            }
        }
        .frame(width: size.width, height: size.height)
        .background(Color(NSColor.windowBackgroundColor))
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Screenshot Generator Tests

final class StashDocsScreenshotTests: XCTestCase {

    @MainActor
    private func assertNoCalloutOverlaps(callouts: [DocCallout], size: CGSize, path: String) {
        let canvasBounds = CGRect(origin: .zero, size: size).insetBy(dx: 4, dy: 4)
        for i in 0..<callouts.count {
            let a = callouts[i]
            let badgeA = a.estimatedBadgeRect
            XCTAssertTrue(
                canvasBounds.contains(badgeA),
                "Callout #\(a.number) (\(a.title)) in \(URL(fileURLWithPath: path).lastPathComponent) clips outside canvas bounds: \(badgeA)"
            )
            XCTAssertFalse(
                badgeA.intersects(a.targetRect.insetBy(dx: 2, dy: 2)),
                "Callout #\(a.number) (\(a.title)) badge overlaps its own targetRect in \(URL(fileURLWithPath: path).lastPathComponent)"
            )
            for j in (i + 1)..<callouts.count {
                let b = callouts[j]
                let badgeB = b.estimatedBadgeRect
                XCTAssertFalse(
                    badgeA.intersects(badgeB),
                    "Callout #\(a.number) (\(a.title)) overlaps Callout #\(b.number) (\(b.title)) in \(URL(fileURLWithPath: path).lastPathComponent)"
                )
                XCTAssertFalse(
                    a.targetRect.insetBy(dx: 2, dy: 2).intersects(b.targetRect.insetBy(dx: 2, dy: 2)),
                    "TargetRect #\(a.number) overlaps TargetRect #\(b.number) in \(URL(fileURLWithPath: path).lastPathComponent)"
                )
            }
        }
    }

    @MainActor
    private func renderAnnotatedScreenshot<V: View>(
        _ view: V,
        callouts: [DocCallout],
        size: CGSize = CGSize(width: 1280, height: 800),
        to path: String
    ) throws {
        assertNoCalloutOverlaps(callouts: callouts, size: size, path: path)

        let annotated = AnnotatedScreenshotCanvas(size: size, callouts: callouts) {
            view
        }

        let hostingView = NSHostingView(rootView: annotated)
        hostingView.appearance = NSAppearance(named: .darkAqua)
        hostingView.frame = NSRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(red: 0.11, green: 0.12, blue: 0.15, alpha: 1.0)
        window.contentView = hostingView
        window.displayIfNeeded()
        hostingView.layoutSubtreeIfNeeded()

        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        hostingView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        guard let bitmapRep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            XCTFail("Failed to create bitmapImageRep for \(path)")
            return
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmapRep)

        guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
            XCTFail("Failed to encode PNG for \(path)")
            return
        }

        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try pngData.write(to: url)

        if !callouts.isEmpty && path.hasSuffix(".png") {
            try renderAnnotatedScreenshot(view, callouts: [], size: size, to: String(path.dropLast(4)) + "_clean.png")
        }
    }

    @MainActor
    @ViewBuilder
    private func makeSnapshotShell<Middle: View, Detail: View>(
        store: StashStore,
        aiPrefs: AIPrefsStore,
        helpModel: HelpOverlayModel,
        middleWidth: CGFloat = 475,
        @ViewBuilder middle: () -> Middle,
        @ViewBuilder detail: () -> Detail
    ) -> some View {
        HStack(spacing: 0) {
            SidebarView(
                selection: .constant(store.navigation),
                showAddCollectionSheet: .constant(false)
            )
            .frame(width: 215)
            .frame(maxHeight: .infinity)
            Divider()
            middle()
                .frame(width: middleWidth)
                .frame(maxHeight: .infinity)
            Divider()
            detail()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .environment(store)
        .environment(aiPrefs)
        .environment(helpModel)
    }

    /// Generates a synthetic diagram thumbnail NSImage and registers it in ThumbnailCache.
    @MainActor
    private func makeSyntheticThumbnail(
        relativePath: String,
        title: String,
        subtitle: String,
        accent: NSColor,
        secondary: NSColor
    ) {
        let size = NSSize(width: 320, height: 320)
        let img = NSImage(size: size)
        img.lockFocus()

        let rect = NSRect(origin: .zero, size: size)
        let gradient = NSGradient(starting: accent, ending: secondary)
        gradient?.draw(in: rect, angle: 135)

        // Subtle grid pattern
        NSColor.white.withAlphaComponent(0.12).setStroke()
        let gridPath = NSBezierPath()
        gridPath.lineWidth = 1.0
        for step in stride(from: 32, to: 320, by: 32) {
            gridPath.move(to: NSPoint(x: CGFloat(step), y: 0))
            gridPath.line(to: NSPoint(x: CGFloat(step), y: 320))
            gridPath.move(to: NSPoint(x: 0, y: CGFloat(step)))
            gridPath.line(to: NSPoint(x: 320, y: CGFloat(step)))
        }
        gridPath.stroke()

        // Inner card frame
        let cardRect = NSRect(x: 24, y: 80, width: 272, height: 170)
        NSColor.black.withAlphaComponent(0.38).setFill()
        NSBezierPath(roundedRect: cardRect, xRadius: 12, yRadius: 12).fill()
        NSColor.white.withAlphaComponent(0.35).setStroke()
        let border = NSBezierPath(roundedRect: cardRect, xRadius: 12, yRadius: 12)
        border.lineWidth = 1.5
        border.stroke()

        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 16, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let subAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.85)
        ]
        (title as NSString).draw(in: NSRect(x: 40, y: 168, width: 240, height: 48), withAttributes: titleAttrs)
        (subtitle as NSString).draw(in: NSRect(x: 40, y: 112, width: 240, height: 40), withAttributes: subAttrs)

        img.unlockFocus()

        if let url = FilePathResolver.resolveRelative(relativePath) {
            ThumbnailCache.shared.inject(img, forPath: url.path)
        }
    }

    @MainActor
    private func buildSyntheticStore() -> StashStore {
        let store = StashStore(disableCLIFetch: true)
        let now = Date()

        let tags: [StashTag] = [
            StashTag(id: 1, name: "go", count: 42),
            StashTag(id: 2, name: "systems", count: 31),
            StashTag(id: 3, name: "postgres", count: 19),
            StashTag(id: 4, name: "ebpf", count: 14),
            StashTag(id: 5, name: "kubernetes", count: 23),
            StashTag(id: 6, name: "security", count: 16),
            StashTag(id: 7, name: "fav", count: 9),
            StashTag(id: 8, name: "read-later", count: 6)
        ]
        store.tags = tags

        let collections: [StashCollection] = [
            StashCollection(id: 1, name: "Systems Architecture", description: "Distributed systems & runtime papers"),
            StashCollection(id: 2, name: "Homelab Infrastructure", description: "k3s, BGP & storage runbooks"),
            StashCollection(id: 3, name: "Database Internals", description: "WAL, MVCC & replication notes")
        ]
        store.collections = collections
        store.topCollections = collections

        store.savedSearches = [
            SavedSearch(
                id: 1,
                name: "Go Runtime Deep Dives",
                query: "scheduler",
                filter: SavedSearch.SearchFilter(type: "url", tags: ["go", "systems"]),
                live: true
            ),
            SavedSearch(
                id: 2,
                name: "Untagged Captures",
                query: "",
                filter: SavedSearch.SearchFilter(untagged: true),
                live: true
            )
        ]

        let item1 = StashItem(
            id: "01J9STASH01GORUNTIME",
            type: .url,
            title: "Go 1.24 SwissTable Map & Runtime Scheduler Deep Dive",
            url: "https://go.dev/blog/swisstable-maps-runtime",
            notes: """
            Key takeaways for high-throughput worker pools:
            - SwissTable metadata bytes use SIMD probe groups (8 slots per group)
            - P99 map lookup latency drops by 28% on 64-byte string keys
            - Pair with GOMEMLIMIT=4GiB on k3s worker nodes
            """,
            extractedText: """
            Go 1.24 replaces the classic bucket-chain map implementation with SwissTable probe groups.
            Each control byte stores a 7-bit H2 hash fingerprint plus tombstones for lock-free reads.
            """,
            mimeType: "text/html",
            fileSize: 48_920,
            metadata: ItemMetadata(language: "en", camera: nil),
            createdAt: now.addingTimeInterval(-3600),
            updatedAt: now.addingTimeInterval(-1800),
            capturedAt: now.addingTimeInterval(-3600),
            location: ItemLocation(lat: 37.7897, lon: -122.4014, source: "manual"),
            tags: [
                StashTag(id: 1, name: "go", count: 42),
                StashTag(id: 2, name: "systems", count: 31),
                StashTag(id: 7, name: "fav", count: 9)
            ],
            collections: [collections[0]],
            links: [
                StashLink(
                    itemId: "01J9STASH02EBPFDIAG",
                    title: "eBPF Socket Map Routing Architecture Diagram",
                    type: .image,
                    label: "benchmarks",
                    direction: "outgoing"
                )
            ]
        )

        let item2 = StashItem(
            id: "01J9STASH02EBPFDIAG",
            type: .image,
            title: "eBPF Socket Map Routing Architecture Diagram",
            sourcePath: "/Users/operator/Diagrams/ebpf-sockmap-routing.png",
            mimeType: "image/png",
            fileSize: 642_110,
            thumbnailPath: "thumbnails/01J9STASH02EBPFDIAG.jpg",
            createdAt: now.addingTimeInterval(-14_400),
            updatedAt: now.addingTimeInterval(-14_400),
            capturedAt: now.addingTimeInterval(-14_400),
            tags: [
                StashTag(id: 4, name: "ebpf", count: 14),
                StashTag(id: 2, name: "systems", count: 31)
            ],
            collections: [collections[0]]
        )

        let item3 = StashItem(
            id: "01J9STASH03PGWALDOC",
            type: .snippet,
            title: "PostgreSQL 17 Logical Failover Slot Verification Snippet",
            notes: "Run before promoting standby replica during maintenance window.",
            extractedText: "SELECT slot_name, synced, active FROM pg_replication_slots WHERE failover = true;",
            mimeType: "text/plain",
            fileSize: 1_840,
            createdAt: now.addingTimeInterval(-28_800),
            updatedAt: now.addingTimeInterval(-28_800),
            tags: [
                StashTag(id: 3, name: "postgres", count: 19),
                StashTag(id: 2, name: "systems", count: 31)
            ],
            collections: [collections[2]]
        )

        let item4 = StashItem(
            id: "01J9STASH04K8SGATEWAY",
            type: .file,
            title: "k3s-cilium-gateway-api-rollout.pdf",
            sourcePath: "/Users/operator/Docs/k3s-cilium-gateway-api-rollout.pdf",
            mimeType: "application/pdf",
            fileSize: 1_420_800,
            createdAt: now.addingTimeInterval(-86_400),
            updatedAt: now.addingTimeInterval(-86_400),
            tags: [
                StashTag(id: 5, name: "kubernetes", count: 23),
                StashTag(id: 4, name: "ebpf", count: 14)
            ],
            collections: [collections[1]]
        )

        let item5 = StashItem(
            id: "01J9STASH05SECADVISORY",
            type: .email,
            title: "Security Advisory: OpenSSH Post-Quantum Key Exchange Default",
            extractedText: "From: Security Team <security@example.org>\nSubject: OpenSSH sntrup761x25519-sha512 default rollout",
            mimeType: "message/rfc822",
            fileSize: 12_400,
            createdAt: now.addingTimeInterval(-172_800),
            updatedAt: now.addingTimeInterval(-172_800),
            tags: [
                StashTag(id: 6, name: "security", count: 16),
                StashTag(id: 8, name: "read-later", count: 6)
            ],
            collections: [collections[1]]
        )

        store.items = [item1, item2, item3, item4, item5]
        store.seenItemIDs = Set(store.items.map(\.id))
        store.selectedItemID = item1.id
        store.selectedItems = [item1.id]

        store.syntheticRelatedItems[item1.id] = [item2, item3]
        store.syntheticProvenance[item1.id] = [
            ProvenanceEvent(
                timestamp: now.addingTimeInterval(-3600),
                kind: "capture",
                summary: "Captured URL from https://go.dev/blog/swisstable-maps-runtime"
            ),
            ProvenanceEvent(
                timestamp: now.addingTimeInterval(-3598),
                kind: "rule",
                summary: "Rule 'go-blog-auto-tag' added tags #go #systems → Systems Architecture",
                rule: "go-blog-auto-tag"
            ),
            ProvenanceEvent(
                timestamp: now.addingTimeInterval(-1800),
                kind: "tag",
                summary: "Added tag #fav (starred in detail pane)",
                tag: "fav",
                action: "add"
            )
        ]

        // Inbox synthetic data
        store.queueItems = [item5, item3]
        let candidate1 = FeedCandidate(
            id: 101,
            sourceId: 1,
            sourceName: "Go Official Blog",
            guid: "https://go.dev/blog/execution-traces-2026",
            url: "https://go.dev/blog/execution-traces-2026",
            title: "Flight Recorder & Low-Overhead Execution Traces in Go",
            description: "Continuous ring-buffer flight recording for production services.",
            descriptionMarkdown: """
            ### Continuous Flight Recording in Production

            Go's execution tracer now supports a lightweight **FlightRecorder** ring buffer that retains the last 5 seconds of goroutine scheduling, syscall blocking, and heap sweep events with **< 1% CPU overhead**.

            - Snapshot traces automatically when HTTP handler latency exceeds `250ms`
            - Inspect goroutine wait profiles with `go tool trace`
            - Zero disk I/O until a trigger condition writes the ring buffer to disk
            """,
            publishedAt: now.addingTimeInterval(-5400),
            discoveredAt: now.addingTimeInterval(-3600),
            state: "unread",
            stateChangedAt: now.addingTimeInterval(-3600)
        )
        let candidate2 = FeedCandidate(
            id: 102,
            sourceId: 2,
            sourceName: "LWN.net Kernel",
            guid: "https://lwn.net/Articles/991204/",
            url: "https://lwn.net/Articles/991204/",
            title: "Zero-Copy TCP Receive with io_uring Provided Buffers",
            description: "Kernel netdev benchmarks for ring-mapped NIC page pools.",
            descriptionMarkdown: "Kernel netdev benchmarks for ring-mapped NIC page pools.",
            publishedAt: now.addingTimeInterval(-18_000),
            discoveredAt: now.addingTimeInterval(-14_400),
            state: "unread",
            stateChangedAt: now.addingTimeInterval(-14_400)
        )
        store.feedCandidates = [candidate1, candidate2]
        store.resurfaceItems = [item2, item4]
        store.inboxSelectedCandidate = candidate1
        store.lastFeedPoll = now.addingTimeInterval(-420)

        // Rules synthetic data
        let rule1 = Rule(
            name: "invoice-pdfs",
            description: "Auto-tag PDF invoices, extract dollar totals into the title, and file under Finance",
            enabled: true,
            match: RuleMatch(
                mimeType: "application/pdf",
                contentRegex: "(?i)Total[:\\s]+(?P<amount>\\$[0-9.,]+)"
            ),
            actions: [
                RuleAction(
                    addTags: ["invoice", "finance"],
                    addCollection: "Finance & Receipts",
                    setTitle: "Invoice {{.Captures.amount}} ({{.Date}})",
                    notify: "Invoice captured: {{.Captures.amount}}"
                )
            ]
        )
        let rule2 = Rule(
            name: "go-blog-auto-tag",
            description: "Tag Go blog and proposal links and route to Systems Architecture",
            enabled: true,
            match: RuleMatch(type: "url", domain: "go.dev"),
            actions: [
                RuleAction(addTags: ["go", "systems"], addCollection: "Systems Architecture")
            ]
        )
        let rule3 = Rule(
            name: "youtube-watch-later",
            description: "Queue YouTube technical talks into watch-later",
            enabled: true,
            match: RuleMatch(domain: "youtube.com"),
            actions: [
                RuleAction(addTags: ["video", "watch-later"])
            ]
        )
        let rule4 = Rule(
            name: "drop-promo-emails",
            description: "Drop automated marketing newsletters before they enter the stash",
            enabled: true,
            match: RuleMatch(type: "email", senderDomain: "marketing.example.com"),
            actions: [
                RuleAction(skip: true)
            ]
        )
        store.rules = [rule1, rule2, rule3, rule4]
        store.selectedRuleName = rule1.name

        // Moments synthetic data
        let mItems1: [StashCLI.MomentSuggestion.MomentItem] = [
            .init(id: "M01", title: "eBPF Sockmap Datapath Topology", type: "image", thumbnailPath: "thumbnails/m01.jpg", storePath: nil),
            .init(id: "M02", title: "Cilium XDP Load Balancer Flow", type: "image", thumbnailPath: "thumbnails/m02.jpg", storePath: nil),
            .init(id: "M03", title: "BGP Route Reflector Rack Layout", type: "image", thumbnailPath: "thumbnails/m03.jpg", storePath: nil),
            .init(id: "M04", title: "NVMe-oF Storage Mesh Latency", type: "image", thumbnailPath: "thumbnails/m04.jpg", storePath: nil),
            .init(id: "M05", title: "CoreDNS Split-Horizon Zone Graph", type: "image", thumbnailPath: "thumbnails/m05.jpg", storePath: nil),
            .init(id: "M06", title: "WireGuard Site-to-Site Mesh Spec", type: "image", thumbnailPath: "thumbnails/m06.jpg", storePath: nil)
        ]
        let moment1 = StashCLI.MomentSuggestion(
            start: now.addingTimeInterval(-86_400 * 3),
            end: now.addingTimeInterval(-86_400 * 3 + 7200),
            itemCount: 6,
            items: mItems1,
            suggestedName: "systems — 2026-10-15",
            score: 94.0,
            sharedTags: ["systems", "ebpf", "homelab"],
            locationCenter: .init(lat: 37.7897, lon: -122.4014),
            locationCount: 6,
            signature: "sig-moment-systems-2026-10-15"
        )
        let moment2 = StashCLI.MomentSuggestion(
            start: now.addingTimeInterval(-86_400 * 11),
            end: now.addingTimeInterval(-86_400 * 10),
            itemCount: 5,
            items: Array(mItems1.prefix(5)),
            suggestedName: "postgres — 2026-10-07",
            score: 82.0,
            sharedTags: ["postgres", "benchmarks"],
            locationCenter: nil,
            locationCount: nil,
            signature: "sig-moment-postgres-2026-10-07"
        )
        store.moments = [moment1, moment2]
        store.selectedMoment = moment1
        store.selectedMomentItemIDs = Set(mItems1.map(\.id))
        store.momentVisionHints = [
            moment1.signature: MomentVision.ClusterHint(label: "diagrams", coverage: 0.83, confidence: 0.91),
            moment2.signature: MomentVision.ClusterHint(label: "charts", coverage: 0.80, confidence: 0.88)
        ]

        return store
    }

    @MainActor
    func testGenerateDocumentationScreenshots() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("stash-docs-screenshots-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        FilePathResolver.customFilesDir = tempDir
        defer {
            FilePathResolver.customFilesDir = nil
            try? FileManager.default.removeItem(at: tempDir)
        }

        // Pre-populate synthetic thumbnails in ThumbnailCache
        makeSyntheticThumbnail(
            relativePath: "thumbnails/01J9STASH02EBPFDIAG.jpg",
            title: "eBPF SOCKMAP",
            subtitle: "SK_MSG -> Verdict Prog",
            accent: NSColor(calibratedRed: 0.12, green: 0.38, blue: 0.68, alpha: 1.0),
            secondary: NSColor(calibratedRed: 0.08, green: 0.16, blue: 0.30, alpha: 1.0)
        )
        makeSyntheticThumbnail(
            relativePath: "thumbnails/m01.jpg",
            title: "eBPF SOCKMAP",
            subtitle: "L4 Socket Bypass",
            accent: NSColor(calibratedRed: 0.14, green: 0.42, blue: 0.74, alpha: 1.0),
            secondary: NSColor(calibratedRed: 0.07, green: 0.18, blue: 0.34, alpha: 1.0)
        )
        makeSyntheticThumbnail(
            relativePath: "thumbnails/m02.jpg",
            title: "CILIUM XDP",
            subtitle: "Direct Server Return",
            accent: NSColor(calibratedRed: 0.16, green: 0.52, blue: 0.46, alpha: 1.0),
            secondary: NSColor(calibratedRed: 0.06, green: 0.22, blue: 0.22, alpha: 1.0)
        )
        makeSyntheticThumbnail(
            relativePath: "thumbnails/m03.jpg",
            title: "BGP FRR MESH",
            subtitle: "ECMP Anycast Spine",
            accent: NSColor(calibratedRed: 0.46, green: 0.28, blue: 0.68, alpha: 1.0),
            secondary: NSColor(calibratedRed: 0.18, green: 0.10, blue: 0.32, alpha: 1.0)
        )
        makeSyntheticThumbnail(
            relativePath: "thumbnails/m04.jpg",
            title: "NVMe-oF TCP",
            subtitle: "P99 IOPS Telemetry",
            accent: NSColor(calibratedRed: 0.68, green: 0.34, blue: 0.18, alpha: 1.0),
            secondary: NSColor(calibratedRed: 0.28, green: 0.12, blue: 0.08, alpha: 1.0)
        )
        makeSyntheticThumbnail(
            relativePath: "thumbnails/m05.jpg",
            title: "COREDNS ZONE",
            subtitle: "Split-Horizon DNS",
            accent: NSColor(calibratedRed: 0.20, green: 0.48, blue: 0.62, alpha: 1.0),
            secondary: NSColor(calibratedRed: 0.08, green: 0.20, blue: 0.28, alpha: 1.0)
        )
        makeSyntheticThumbnail(
            relativePath: "thumbnails/m06.jpg",
            title: "WIREGUARD",
            subtitle: "Cryptokey Routing",
            accent: NSColor(calibratedRed: 0.56, green: 0.22, blue: 0.38, alpha: 1.0),
            secondary: NSColor(calibratedRed: 0.24, green: 0.08, blue: 0.18, alpha: 1.0)
        )

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let assetsDir = repoRoot.appendingPathComponent("docs/assets")

        let aiPrefs = AIPrefsStore()
        let helpModel = HelpOverlayModel()

        // 1. Stash Workbench (All Items + Tokenized Filter + Item Detail Inspector)
        do {
            let store = buildSyntheticStore()
            store.navigation = .allItems
            store.searchQuery = "tag:go"

            let view = makeSnapshotShell(store: store, aiPrefs: aiPrefs, helpModel: helpModel) {
                ItemListView(showEditSheet: .constant(false))
            } detail: {
                DetailRouter(showEditSheet: .constant(false))
            }

            let callouts: [DocCallout] = [
                DocCallout(
                    number: 1,
                    title: "Library, Collections & Tag Tree",
                    subtitle: "Jump between Inbox, Tools, Rules, Smart Collections & Tags",
                    targetRect: CGRect(x: 6, y: 12, width: 204, height: 540),
                    badgeCenter: CGPoint(x: 160, y: 635),
                    color: .blue
                ),
                DocCallout(
                    number: 2,
                    title: "Tokenized & Regex Search Bar",
                    subtitle: "Filter by tag:, !tag:, collection:, or type // for RE2 regex",
                    targetRect: CGRect(x: 222, y: 4, width: 465, height: 32),
                    badgeCenter: CGPoint(x: 455, y: 585),
                    color: .orange
                ),
                DocCallout(
                    number: 3,
                    title: "Type Chips & View Mode Switcher",
                    subtitle: "Scope to URLs, Snippets, Files, Images, or Emails",
                    targetRect: CGRect(x: 222, y: 40, width: 465, height: 32),
                    badgeCenter: CGPoint(x: 455, y: 685),
                    color: .purple
                ),
                DocCallout(
                    number: 4,
                    title: "Item Inspector & Provenance",
                    subtitle: "Vim notes, GPS location, linked items & capture timeline",
                    targetRect: CGRect(x: 702, y: 12, width: 565, height: 615),
                    badgeCenter: CGPoint(x: 985, y: 715),
                    color: .green
                )
            ]

            try renderAnnotatedScreenshot(
                view,
                callouts: callouts,
                to: assetsDir.appendingPathComponent("stash_workbench.png").path
            )
        }

        // 2. Unified Triage Inbox
        do {
            let store = buildSyntheticStore()
            store.navigation = .inbox

            let view = makeSnapshotShell(store: store, aiPrefs: aiPrefs, helpModel: helpModel) {
                InboxView()
            } detail: {
                InboxDetailView()
            }

            let callouts: [DocCallout] = [
                DocCallout(
                    number: 1,
                    title: "To Read & Watch Queue",
                    subtitle: "Active read-later / watch-later items with 1-click Mark Done",
                    targetRect: CGRect(x: 222, y: 88, width: 465, height: 150),
                    badgeCenter: CGPoint(x: 455, y: 615),
                    color: .blue
                ),
                DocCallout(
                    number: 2,
                    title: "Watched Feed Candidates",
                    subtitle: "Unread RSS & Atom entries ready for J/K/S/X/Z triage",
                    targetRect: CGRect(x: 222, y: 248, width: 465, height: 165),
                    badgeCenter: CGPoint(x: 455, y: 680),
                    color: .orange
                ),
                DocCallout(
                    number: 3,
                    title: "Resurface Picks",
                    subtitle: "Forgotten stash items rotated back so research stays fresh",
                    targetRect: CGRect(x: 222, y: 425, width: 465, height: 155),
                    badgeCenter: CGPoint(x: 455, y: 745),
                    color: .purple
                ),
                DocCallout(
                    number: 4,
                    title: "Markdown Preview & Triage Bar",
                    subtitle: "Read full converted Markdown and Stash, Snooze, or Dismiss",
                    targetRect: CGRect(x: 702, y: 16, width: 565, height: 380),
                    badgeCenter: CGPoint(x: 985, y: 495),
                    color: .green
                )
            ]

            try renderAnnotatedScreenshot(
                view,
                callouts: callouts,
                to: assetsDir.appendingPathComponent("inbox_triage.png").path
            )
        }

        // 3. Capture Rules Engine & Auto-Tagging Editor
        do {
            let store = buildSyntheticStore()
            store.navigation = .rules
            store.initialRuleDetailEditMode = true

            let view = makeSnapshotShell(store: store, aiPrefs: aiPrefs, helpModel: helpModel) {
                RulesView()
            } detail: {
                RuleDetailView()
            }

            let callouts: [DocCallout] = [
                DocCallout(
                    number: 1,
                    title: "Capture Rules Pipeline",
                    subtitle: "Rules in ~/.stash/rules.yaml run on every stash add",
                    targetRect: CGRect(x: 222, y: 45, width: 465, height: 405),
                    badgeCenter: CGPoint(x: 455, y: 545),
                    color: .blue
                ),
                DocCallout(
                    number: 2,
                    title: "AND-Composed Match Conditions",
                    subtitle: "Match MIME type, domain, or named regex capture groups",
                    targetRect: CGRect(x: 702, y: 170, width: 560, height: 96),
                    badgeCenter: CGPoint(x: 985, y: 112),
                    color: .orange
                ),
                DocCallout(
                    number: 3,
                    title: "Templated Rule Actions",
                    subtitle: "Add tags, assign collections, and interpolate {{.Captures.amount}}",
                    targetRect: CGRect(x: 702, y: 278, width: 560, height: 365),
                    badgeCenter: CGPoint(x: 985, y: 715),
                    color: .green
                )
            ]

            try renderAnnotatedScreenshot(
                view,
                callouts: callouts,
                to: assetsDir.appendingPathComponent("capture_rules.png").path
            )
        }

        // 4. Moments Temporal & Vision Clustering
        do {
            let store = buildSyntheticStore()
            store.navigation = .moments

            let view = makeSnapshotShell(store: store, aiPrefs: aiPrefs, helpModel: helpModel) {
                MomentsView()
            } detail: {
                MomentDetailView()
            }

            let callouts: [DocCallout] = [
                DocCallout(
                    number: 1,
                    title: "Temporal & GPS Cluster Cards",
                    subtitle: "Detects bursts of items captured close in time or location",
                    targetRect: CGRect(x: 222, y: 82, width: 465, height: 136),
                    badgeCenter: CGPoint(x: 455, y: 465),
                    color: .blue
                ),
                DocCallout(
                    number: 2,
                    title: "On-Device Vision Scene Badge",
                    subtitle: "Apple Vision summarizes dominant subject with zero cloud calls",
                    targetRect: CGRect(x: 404, y: 234, width: 66, height: 24),
                    badgeCenter: CGPoint(x: 455, y: 555),
                    color: .purple
                ),
                DocCallout(
                    number: 3,
                    title: "Draft Selection Thumbnail Grid",
                    subtitle: "Toggle top-left checkmarks to include or exclude items",
                    targetRect: CGRect(x: 706, y: 82, width: 555, height: 440),
                    badgeCenter: CGPoint(x: 985, y: 635),
                    color: .green
                )
            ]

            try renderAnnotatedScreenshot(
                view,
                callouts: callouts,
                to: assetsDir.appendingPathComponent("moments_clustering.png").path
            )
        }
    }
}
