import Foundation
import Testing

@testable import StashMac

/// Pure-logic tests for the on-device Suggest Rules pipeline. These
/// helpers are deterministic — they take events / rules / items and
/// return shapes — so testing them is high-leverage and cheap. The
/// Foundation Models call itself is hardware-gated and not unit-
/// tested here.
@MainActor
@Suite("RuleSuggestionService static helpers")
struct RuleSuggestionServiceTests {
    // MARK: - bucketByTag

    @Test("bucketByTag groups add events by tag")
    func bucketsByTag() {
        let events = [
            addEvent(tag: "video",   itemId: "A"),
            addEvent(tag: "video",   itemId: "B"),
            addEvent(tag: "video",   itemId: "C"),
            addEvent(tag: "fishing", itemId: "D"),
            addEvent(tag: "fishing", itemId: "E"),
        ]
        let buckets = RuleSuggestionService.bucketByTag(events: events, minSupporting: 2)
        let byTag = Dictionary(uniqueKeysWithValues: buckets.map { ($0.tag, $0.events.count) })
        #expect(byTag["video"] == 3)
        #expect(byTag["fishing"] == 2)
    }

    @Test("bucketByTag drops tags below minSupporting")
    func dropsBelowThreshold() {
        let events = [
            addEvent(tag: "video", itemId: "A"),
            addEvent(tag: "video", itemId: "B"),
            addEvent(tag: "rare",  itemId: "C"),  // only 1
        ]
        let buckets = RuleSuggestionService.bucketByTag(events: events, minSupporting: 2)
        #expect(buckets.map(\.tag) == ["video"])
    }

    @Test("bucketByTag dedupes by item id within a tag")
    func dedupesPerItem() {
        // Same item tagged + retagged shouldn't inflate the bucket.
        let events = [
            addEvent(tag: "video", itemId: "A"),
            addEvent(tag: "video", itemId: "A"),
            addEvent(tag: "video", itemId: "A"),
        ]
        let buckets = RuleSuggestionService.bucketByTag(events: events, minSupporting: 2)
        #expect(buckets.isEmpty)  // 1 unique item, below threshold
    }

    @Test("bucketByTag ignores remove events")
    func ignoresRemoves() {
        let events = [
            addEvent(tag: "video",   itemId: "A"),
            addEvent(tag: "video",   itemId: "B"),
            removeEvent(tag: "video", itemId: "C"),  // ignored
            removeEvent(tag: "video", itemId: "D"),  // ignored
        ]
        let buckets = RuleSuggestionService.bucketByTag(events: events, minSupporting: 3)
        #expect(buckets.isEmpty)  // only 2 add events for 'video'
    }

    @Test("bucketByTag returns largest buckets first")
    func sortsByCountDescending() {
        let events = (0..<3).map { addEvent(tag: "small", itemId: "s\($0)") }
            + (0..<7).map { addEvent(tag: "big", itemId: "b\($0)") }
            + (0..<5).map { addEvent(tag: "mid", itemId: "m\($0)") }
        let buckets = RuleSuggestionService.bucketByTag(events: events, minSupporting: 3)
        #expect(buckets.map(\.tag) == ["big", "mid", "small"])
    }

    // MARK: - mergeEvents

    @Test("mergeEvents dedupes per (itemId, tag, action) keeping audit-log version")
    func mergeDedupes() {
        let auditTime = Date(timeIntervalSince1970: 1_700_000_000)
        let snapTime = Date(timeIntervalSince1970: 0)
        let audit = [makeEvent(action: "add", tag: "x", itemId: "A", at: auditTime, source: "edit")]
        let snapshot = [makeEvent(action: "add", tag: "x", itemId: "A", at: snapTime, source: "snapshot")]

        let merged = RuleSuggestionService.mergeEvents(audit: audit, snapshot: snapshot)
        #expect(merged.count == 1)
        // Audit-log entry wins (it has the real timestamp).
        #expect(merged[0].timestamp == auditTime)
        #expect(merged[0].source == "edit")
    }

    @Test("mergeEvents preserves distinct events from both lists")
    func mergeKeepsDistinct() {
        let audit = [addEvent(tag: "a", itemId: "1")]
        let snapshot = [addEvent(tag: "b", itemId: "2", source: "snapshot")]
        let merged = RuleSuggestionService.mergeEvents(audit: audit, snapshot: snapshot)
        #expect(merged.count == 2)
        #expect(Set(merged.map(\.tag)) == ["a", "b"])
    }

    // MARK: - tagsCoveredByEnabledRules

    @Test("tagsCoveredByEnabledRules collects addTags from enabled rules only")
    func collectsCoveredTags() {
        let rules = [
            rule(name: "yt",      enabled: true,  addTags: ["video", "watch"]),
            rule(name: "off",     enabled: false, addTags: ["should-not-appear"]),
            rule(name: "fishing", enabled: nil,   addTags: ["outdoor"]),  // nil = enabled
        ]
        let covered = RuleSuggestionService.tagsCoveredByEnabledRules(rules)
        #expect(covered == ["video", "watch", "outdoor"])
    }

    @Test("tagsCoveredByEnabledRules returns empty for empty input")
    func coveredEmptyForEmpty() {
        #expect(RuleSuggestionService.tagsCoveredByEnabledRules([]).isEmpty)
    }

    // MARK: - eventsFromItemSnapshot

    @Test("eventsFromItemSnapshot synthesizes one add event per (item, tag) pair")
    func snapshotPerTag() {
        let items = [
            stashItem(id: "A", url: "https://www.youtube.com/watch?v=x", tags: ["video", "watch"]),
            stashItem(id: "B", url: "https://example.com",            tags: ["doc"]),
        ]
        let events = RuleSuggestionService.eventsFromItemSnapshot(items: items)
        #expect(events.count == 3)
        #expect(events.allSatisfy { $0.action == "add" && $0.source == "snapshot" })
    }

    @Test("eventsFromItemSnapshot strips www. and lowercases domain")
    func snapshotDomainExtraction() {
        let items = [stashItem(id: "A", url: "https://WWW.YouTube.com/path", tags: ["video"])]
        let events = RuleSuggestionService.eventsFromItemSnapshot(items: items)
        #expect(events.first?.itemDomain == "youtube.com")
    }

    @Test("eventsFromItemSnapshot skips untagged items")
    func snapshotSkipsUntagged() {
        let items = [
            stashItem(id: "A", url: "https://example.com", tags: ["x"]),
            stashItem(id: "B", url: "https://example.com", tags: nil),
            stashItem(id: "C", url: "https://example.com", tags: []),
        ]
        let events = RuleSuggestionService.eventsFromItemSnapshot(items: items)
        #expect(events.count == 1)
        #expect(events[0].itemId == "A")
    }

    // MARK: - Helpers

    private func addEvent(tag: String, itemId: String, source: String = "edit") -> TagEvent {
        makeEvent(action: "add", tag: tag, itemId: itemId, at: Date(), source: source)
    }

    private func removeEvent(tag: String, itemId: String) -> TagEvent {
        makeEvent(action: "remove", tag: tag, itemId: itemId, at: Date(), source: "edit")
    }

    private func makeEvent(action: String, tag: String, itemId: String, at: Date, source: String) -> TagEvent {
        TagEvent(
            timestamp: at,
            action: action,
            tag: tag,
            itemId: itemId,
            itemType: "link",
            itemUrl: "https://example.com/\(itemId)",
            itemDomain: "example.com",
            source: source
        )
    }

    private func rule(name: String, enabled: Bool?, addTags: [String]) -> Rule {
        Rule(
            name: name,
            enabled: enabled,
            match: RuleMatch(),
            actions: [RuleAction(addTags: addTags)]
        )
    }

    private func stashItem(id: String, url: String, tags: [String]?) -> StashItem {
        let tagModels = tags?.enumerated().map { idx, name in
            StashTag(id: Int64(idx + 1), name: name, count: nil)
        }
        return StashItem(
            id: id,
            type: .url,
            title: id,
            url: url,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            tags: tagModels
        )
    }
}
