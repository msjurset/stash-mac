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
