import Foundation
import Testing

@testable import StashMac

@Test func testDecodeStashItem() throws {
    let json = """
    {
        "id": "01HQ3XYZABC123456789",
        "type": "link",
        "title": "Example Page",
        "url": "https://example.com",
        "notes": "A test note",
        "mime_type": "text/html",
        "file_size": 2048,
        "created_at": "2024-01-15T10:30:00Z",
        "updated_at": "2024-01-15T10:30:00Z",
        "tags": [{"id": 1, "name": "research"}],
        "collections": [{"id": 1, "name": "Reading List"}]
    }
    """
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    decoder.dateDecodingStrategy = .iso8601

    let item = try decoder.decode(StashItem.self, from: Data(json.utf8))
    #expect(item.id == "01HQ3XYZABC123456789")
    #expect(item.type == .url)
    #expect(item.title == "Example Page")
    #expect(item.url == "https://example.com")
    #expect(item.notes == "A test note")
    #expect(item.mimeType == "text/html")
    #expect(item.fileSize == 2048)
    #expect(item.tags?.count == 1)
    #expect(item.tags?.first?.name == "research")
    #expect(item.collections?.count == 1)
    #expect(item.collections?.first?.name == "Reading List")
    #expect(item.shortID == "01HQ3XYZAB")
    #expect(item.humanFileSize == "2.0 KB")
}

@Test func testDecodeTag() throws {
    let json = """
    {"id": 42, "name": "golang"}
    """
    let tag = try JSONDecoder().decode(StashTag.self, from: Data(json.utf8))
    #expect(tag.id == 42)
    #expect(tag.name == "golang")
}

@Test func testDecodeCollection() throws {
    let json = """
    {"id": 7, "name": "Reading List", "description": "Stuff to read"}
    """
    let col = try JSONDecoder().decode(StashCollection.self, from: Data(json.utf8))
    #expect(col.id == 7)
    #expect(col.name == "Reading List")
    #expect(col.description == "Stuff to read")
}

@Test func testDecodeItemArray() throws {
    let json = """
    [
        {"id": "A", "type": "snippet", "title": "Note 1", "created_at": "2024-01-01T00:00:00Z", "updated_at": "2024-01-01T00:00:00Z"},
        {"id": "B", "type": "file", "title": "Doc.pdf", "created_at": "2024-02-01T00:00:00Z", "updated_at": "2024-02-01T00:00:00Z"}
    ]
    """
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    decoder.dateDecodingStrategy = .iso8601

    let items = try decoder.decode([StashItem].self, from: Data(json.utf8))
    #expect(items.count == 2)
    #expect(items[0].type == .snippet)
    #expect(items[1].type == .file)
}

@Test func testItemTypeProperties() {
    #expect(ItemType.url.icon == "globe")
    #expect(ItemType.snippet.icon == "doc.text")
    #expect(ItemType.file.icon == "doc")
    #expect(ItemType.image.icon == "photo")
    #expect(ItemType.url.label == "URLs")
}

@Test func testHumanFileSize() throws {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    decoder.dateDecodingStrategy = .iso8601

    let json = """
    {"id": "X", "type": "file", "title": "Big", "file_size": 1048576, "created_at": "2024-01-01T00:00:00Z", "updated_at": "2024-01-01T00:00:00Z"}
    """
    let item = try decoder.decode(StashItem.self, from: Data(json.utf8))
    #expect(item.humanFileSize == "1.0 MB")
}

@Test func testFeedSourceHealthAndDecoding() throws {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    decoder.dateDecodingStrategy = .iso8601

    let healthyJSON = """
    {
        "id": 3,
        "name": "Daring Fireball",
        "kind": "rss",
        "url": "https://daringfireball.net/feeds/main",
        "fetch_content": true,
        "poll_interval_minutes": 360,
        "enabled": true,
        "last_polled_at": "2026-10-31T12:54:44Z",
        "created_at": "2026-05-12T23:51:56Z",
        "updated_at": "2026-10-31T12:54:44Z"
    }
    """
    let healthy = try decoder.decode(FeedSource.self, from: Data(healthyJSON.utf8))
    #expect(healthy.id == 3)
    #expect(healthy.fetchContent == true)
    #expect(!healthy.hasError)
    #expect(healthy.isHealthy)

    let erroredJSON = """
    {
        "id": 5,
        "name": "NASA APOD",
        "kind": "rss",
        "url": "https://apod.nasa.gov/apod.rss",
        "default_tags": ["space"],
        "poll_interval_minutes": 360,
        "enabled": true,
        "last_polled_at": "2026-10-31T12:54:45Z",
        "last_error": "unknown feed root: \\"html\\"",
        "created_at": "2026-05-12T23:53:16Z",
        "updated_at": "2026-10-31T12:54:45Z"
    }
    """
    let errored = try decoder.decode(FeedSource.self, from: Data(erroredJSON.utf8))
    #expect(errored.hasError)
    #expect(!errored.isHealthy)
    #expect(errored.lastError == "unknown feed root: \"html\"")
}

@Test func testFeedRefreshResponseAndCandidateStats() throws {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    decoder.dateDecodingStrategy = .iso8601

    let refreshJSON = """
    {
        "snoozed_expired": 1,
        "sources": [
            {
                "source": "Daring Fireball",
                "found": 48,
                "new": 2,
                "enriched": 2
            }
        ]
    }
    """
    let resp = try decoder.decode(FeedRefreshResponse.self, from: Data(refreshJSON.utf8))
    #expect(resp.snoozedExpired == 1)
    #expect(resp.sources.count == 1)
    #expect(resp.sources.first?.found == 48)
    #expect(resp.sources.first?.new == 2)
    #expect(resp.sources.first?.enriched == 2)

    let now = Date()
    let cands = [
        FeedCandidate(id: 1, sourceId: 3, guid: "a", url: "https://example.com/1", discoveredAt: now, state: "unread", stateChangedAt: now),
        FeedCandidate(id: 2, sourceId: 3, guid: "b", url: "https://example.com/2", discoveredAt: now, state: "stashed", stateChangedAt: now),
        FeedCandidate(id: 3, sourceId: 3, guid: "c", url: "https://example.com/3", discoveredAt: now, state: "dismissed", stateChangedAt: now),
        FeedCandidate(id: 4, sourceId: 3, guid: "d", url: "https://example.com/4", discoveredAt: now, state: "unread", stateChangedAt: now),
    ]
    let stats = FeedCandidateStats(candidates: cands)
    #expect(stats.unread == 2)
    #expect(stats.stashed == 1)
    #expect(stats.dismissed == 1)
    #expect(stats.snoozed == 0)
    #expect(stats.total == 4)
}

@MainActor
@Test func testGraphSimulationFocusRingAndNeighbors() {
    let data = TagGraphData(
        nodes: [
            StashTag(id: 1, name: "center-tag", count: 20),
            StashTag(id: 2, name: "neighbor-a", count: 10),
            StashTag(id: 3, name: "neighbor-b", count: 8),
            StashTag(id: 4, name: "outer-node", count: 5),
        ],
        edges: [
            TagEdge(tagA: "center-tag", tagB: "neighbor-a", weight: 5),
            TagEdge(tagA: "center-tag", tagB: "neighbor-b", weight: 3),
        ]
    )
    let sim = GraphSimulation()
    sim.setup(data: data, canvasSize: CGSize(width: 800, height: 600))
    sim.stop()

    let neighbors = sim.neighborIndices(of: 0)
    #expect(neighbors == [1, 2])

    sim.focusNode(at: 0, canvasSize: CGSize(width: 800, height: 600))
    #expect(sim.focusedNodeIndex == 0)
    #expect(sim.focusedTagName == "center-tag")
    #expect(sim.focusedNeighborIndices == Set([1, 2]))
    #expect(sim.focusRingTargets.count == 2)

    sim.clearFocus()
    #expect(sim.focusedNodeIndex == nil)
    #expect(sim.focusedNeighborIndices.isEmpty)
}

@MainActor
@Test func testTagGraphFilterToggles() {
    let data = TagGraphData(
        nodes: [
            StashTag(id: 1, name: "hub", count: 10),
            StashTag(id: 2, name: "connected", count: 4),
            StashTag(id: 3, name: "single-connected", count: 1),
            StashTag(id: 4, name: "orphan-multi", count: 3),
            StashTag(id: 5, name: "orphan-single", count: 1),
        ],
        edges: [
            TagEdge(tagA: "hub", tagB: "connected", weight: 3),
            TagEdge(tagA: "hub", tagB: "single-connected", weight: 1),
        ]
    )

    let minTwo = TagGraphView.filterGraphData(data, minCountTwo: true, hideOrphans: false)
    #expect(minTwo.nodes.map(\.name) == ["hub", "connected", "orphan-multi"])
    #expect(minTwo.edges.count == 1)

    let noOrphans = TagGraphView.filterGraphData(data, minCountTwo: false, hideOrphans: true)
    #expect(noOrphans.nodes.map(\.name) == ["hub", "connected", "single-connected"])
    #expect(noOrphans.edges.count == 2)

    let both = TagGraphView.filterGraphData(data, minCountTwo: true, hideOrphans: true)
    #expect(both.nodes.map(\.name) == ["hub", "connected"])
    #expect(both.edges.count == 1)
}
