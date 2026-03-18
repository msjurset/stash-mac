import Foundation
import Testing

@testable import StashMac

// MARK: - Helpers

private func makeDecoder() -> JSONDecoder {
    let d = JSONDecoder()
    d.keyDecodingStrategy = .convertFromSnakeCase
    d.dateDecodingStrategy = .iso8601
    return d
}

private func decodeItem(_ json: String) throws -> StashItem {
    try makeDecoder().decode(StashItem.self, from: Data(json.utf8))
}

// MARK: - shortID

@Test func testShortIDTruncatesLongIDs() throws {
    let item = try decodeItem("""
    {"id": "ABCDEFGHIJKLMNOP", "type": "link", "title": "T",
     "created_at": "2024-01-01T00:00:00Z", "updated_at": "2024-01-01T00:00:00Z"}
    """)
    #expect(item.shortID == "ABCDEFGHIJ")
    #expect(item.shortID.count == 10)
}

@Test func testShortIDPreservesShortIDs() throws {
    let item = try decodeItem("""
    {"id": "ABC", "type": "link", "title": "T",
     "created_at": "2024-01-01T00:00:00Z", "updated_at": "2024-01-01T00:00:00Z"}
    """)
    #expect(item.shortID == "ABC")
}

@Test func testShortIDExactlyTenChars() throws {
    let item = try decodeItem("""
    {"id": "0123456789", "type": "link", "title": "T",
     "created_at": "2024-01-01T00:00:00Z", "updated_at": "2024-01-01T00:00:00Z"}
    """)
    #expect(item.shortID == "0123456789")
}

// MARK: - humanFileSize

@Test func testHumanFileSizeBytes() throws {
    let item = try decodeItem("""
    {"id": "X", "type": "file", "title": "T", "file_size": 512,
     "created_at": "2024-01-01T00:00:00Z", "updated_at": "2024-01-01T00:00:00Z"}
    """)
    #expect(item.humanFileSize == "512 B")
}

@Test func testHumanFileSizeKilobytes() throws {
    let item = try decodeItem("""
    {"id": "X", "type": "file", "title": "T", "file_size": 5120,
     "created_at": "2024-01-01T00:00:00Z", "updated_at": "2024-01-01T00:00:00Z"}
    """)
    #expect(item.humanFileSize == "5.0 KB")
}

@Test func testHumanFileSizeGigabytes() throws {
    let item = try decodeItem("""
    {"id": "X", "type": "file", "title": "T", "file_size": 2147483648,
     "created_at": "2024-01-01T00:00:00Z", "updated_at": "2024-01-01T00:00:00Z"}
    """)
    #expect(item.humanFileSize == "2.0 GB")
}

@Test func testHumanFileSizeZero() throws {
    let item = try decodeItem("""
    {"id": "X", "type": "file", "title": "T", "file_size": 0,
     "created_at": "2024-01-01T00:00:00Z", "updated_at": "2024-01-01T00:00:00Z"}
    """)
    #expect(item.humanFileSize == nil)
}

@Test func testHumanFileSizeNil() throws {
    let item = try decodeItem("""
    {"id": "X", "type": "file", "title": "T",
     "created_at": "2024-01-01T00:00:00Z", "updated_at": "2024-01-01T00:00:00Z"}
    """)
    #expect(item.humanFileSize == nil)
}

@Test func testHumanFileSizeOneByte() throws {
    let item = try decodeItem("""
    {"id": "X", "type": "file", "title": "T", "file_size": 1,
     "created_at": "2024-01-01T00:00:00Z", "updated_at": "2024-01-01T00:00:00Z"}
    """)
    #expect(item.humanFileSize == "1 B")
}

// MARK: - tagNames / collectionNames

@Test func testTagNamesWithTags() throws {
    let item = try decodeItem("""
    {"id": "X", "type": "link", "title": "T",
     "tags": [{"id": 1, "name": "go"}, {"id": 2, "name": "cli"}],
     "created_at": "2024-01-01T00:00:00Z", "updated_at": "2024-01-01T00:00:00Z"}
    """)
    #expect(item.tagNames == ["go", "cli"])
}

@Test func testTagNamesWithoutTags() throws {
    let item = try decodeItem("""
    {"id": "X", "type": "link", "title": "T",
     "created_at": "2024-01-01T00:00:00Z", "updated_at": "2024-01-01T00:00:00Z"}
    """)
    #expect(item.tagNames == [])
}

@Test func testCollectionNamesWithCollections() throws {
    let item = try decodeItem("""
    {"id": "X", "type": "link", "title": "T",
     "collections": [{"id": 1, "name": "Research"}],
     "created_at": "2024-01-01T00:00:00Z", "updated_at": "2024-01-01T00:00:00Z"}
    """)
    #expect(item.collectionNames == ["Research"])
}

@Test func testCollectionNamesWithoutCollections() throws {
    let item = try decodeItem("""
    {"id": "X", "type": "link", "title": "T",
     "created_at": "2024-01-01T00:00:00Z", "updated_at": "2024-01-01T00:00:00Z"}
    """)
    #expect(item.collectionNames == [])
}

// MARK: - Optional fields

@Test func testOptionalFieldsNil() throws {
    let item = try decodeItem("""
    {"id": "X", "type": "snippet", "title": "T",
     "created_at": "2024-01-01T00:00:00Z", "updated_at": "2024-01-01T00:00:00Z"}
    """)
    #expect(item.url == nil)
    #expect(item.notes == nil)
    #expect(item.sourcePath == nil)
    #expect(item.storePath == nil)
    #expect(item.contentHash == nil)
    #expect(item.extractedText == nil)
    #expect(item.mimeType == nil)
    #expect(item.fileSize == nil)
    #expect(item.tags == nil)
    #expect(item.collections == nil)
}

// MARK: - ItemType

@Test func testAllItemTypesHaveIcons() {
    for itemType in ItemType.allCases {
        #expect(!itemType.icon.isEmpty)
    }
}

@Test func testAllItemTypesHaveLabels() {
    for itemType in ItemType.allCases {
        #expect(!itemType.label.isEmpty)
    }
}

@Test func testItemTypeRawValues() {
    #expect(ItemType.link.rawValue == "link")
    #expect(ItemType.snippet.rawValue == "snippet")
    #expect(ItemType.file.rawValue == "file")
    #expect(ItemType.image.rawValue == "image")
    #expect(ItemType.email.rawValue == "email")
}

@Test func testItemTypeCount() {
    #expect(ItemType.allCases.count == 5)
}

// MARK: - Collection optional description

@Test func testCollectionWithoutDescription() throws {
    let json = """
    {"id": 1, "name": "Work"}
    """
    let col = try JSONDecoder().decode(StashCollection.self, from: Data(json.utf8))
    #expect(col.name == "Work")
    #expect(col.description == nil)
}

// MARK: - Hashable conformance

@Test func testStashItemHashable() throws {
    let item1 = try decodeItem("""
    {"id": "A", "type": "link", "title": "T",
     "created_at": "2024-01-01T00:00:00Z", "updated_at": "2024-01-01T00:00:00Z"}
    """)
    let item2 = try decodeItem("""
    {"id": "B", "type": "link", "title": "T",
     "created_at": "2024-01-01T00:00:00Z", "updated_at": "2024-01-01T00:00:00Z"}
    """)
    let set: Set<StashItem> = [item1, item2, item1]
    #expect(set.count == 2)
}

@Test func testStashTagHashable() throws {
    let tag1 = try JSONDecoder().decode(StashTag.self, from: Data(#"{"id": 1, "name": "go"}"#.utf8))
    let tag2 = try JSONDecoder().decode(StashTag.self, from: Data(#"{"id": 2, "name": "rust"}"#.utf8))
    let set: Set<StashTag> = [tag1, tag2, tag1]
    #expect(set.count == 2)
}
