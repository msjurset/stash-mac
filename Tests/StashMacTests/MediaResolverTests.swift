import Foundation
import Testing

@testable import StashMac

private func makeItem(
    type: ItemType,
    url: String? = nil,
    storePath: String? = nil,
    sourcePath: String? = nil,
    mimeType: String? = nil
) -> StashItem {
    StashItem(
        id: "01TEST",
        type: type,
        title: "T",
        url: url,
        notes: nil,
        sourcePath: sourcePath,
        storePath: storePath,
        contentHash: nil,
        extractedText: nil,
        mimeType: mimeType,
        fileSize: nil,
        thumbnailPath: nil,
        metadata: nil,
        createdAt: Date(),
        updatedAt: Date(),
        tags: nil,
        collections: nil,
        links: nil
    )
}

// MARK: - URL items

@Test func directVideoURLByExtension() {
    let item = makeItem(type: .url, url: "https://example.com/clip.mp4")
    #expect(MediaResolver.resolve(item) == .directVideo(URL(string: "https://example.com/clip.mp4")!))
}

@Test func directAudioURLByExtension() {
    let item = makeItem(type: .url, url: "https://podcasts.example.com/ep.mp3")
    #expect(MediaResolver.resolve(item) == .directAudio(URL(string: "https://podcasts.example.com/ep.mp3")!))
}

@Test func directVideoURLByMime() {
    // URL has no recognizable extension; mime is the discriminator.
    let item = makeItem(type: .url, url: "https://example.com/stream", mimeType: "video/mp4")
    #expect(MediaResolver.resolve(item) == .directVideo(URL(string: "https://example.com/stream")!))
}

@Test func directAudioURLByMime() {
    let item = makeItem(type: .url, url: "https://example.com/stream", mimeType: "audio/mpeg")
    #expect(MediaResolver.resolve(item) == .directAudio(URL(string: "https://example.com/stream")!))
}

@Test func unknownURLResolvesToNone() {
    // HTML page with no media hints; embed hosts are Phase 2.
    let item = makeItem(type: .url, url: "https://example.com/article")
    #expect(MediaResolver.resolve(item) == .none)
}

@Test func emptyURLResolvesToNone() {
    let item = makeItem(type: .url, url: "")
    #expect(MediaResolver.resolve(item) == .none)
}

// MARK: - Other types

@Test func snippetItemResolvesToNone() {
    let item = makeItem(type: .snippet)
    #expect(MediaResolver.resolve(item) == .none)
}

@Test func emailItemResolvesToNone() {
    let item = makeItem(type: .email)
    #expect(MediaResolver.resolve(item) == .none)
}

@Test func imageItemResolvesToNone() {
    // Image has its own preview path in the detail view; the media
    // resolver explicitly returns .none for it.
    let item = makeItem(type: .image, storePath: "ab/abcdef")
    #expect(MediaResolver.resolve(item) == .none)
}

@Test func fileItemWithoutStorePathResolvesToNone() {
    let item = makeItem(type: .file, mimeType: "video/mp4")
    #expect(MediaResolver.resolve(item) == .none)
}

// MARK: - Embed-host pattern matching

@Test func youtubeWatchURLResolvesToEmbed() {
    let item = makeItem(type: .url, url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
    #expect(MediaResolver.resolve(item) == .embed(URL(string: "https://www.youtube.com/embed/dQw4w9WgXcQ")!))
}

@Test func youtubeShortURLResolvesToEmbed() {
    let item = makeItem(type: .url, url: "https://youtu.be/dQw4w9WgXcQ")
    #expect(MediaResolver.resolve(item) == .embed(URL(string: "https://www.youtube.com/embed/dQw4w9WgXcQ")!))
}

@Test func youtubeShortsURLResolvesToEmbed() {
    let item = makeItem(type: .url, url: "https://www.youtube.com/shorts/abc123")
    #expect(MediaResolver.resolve(item) == .embed(URL(string: "https://www.youtube.com/embed/abc123")!))
}

@Test func youtubeWatchWithExtraParamsResolvesToEmbed() {
    // Real YouTube share URLs carry t=, list=, si= params; we only
    // need v= for the embed.
    let item = makeItem(type: .url, url: "https://www.youtube.com/watch?v=abc123&t=42s&list=foo")
    #expect(MediaResolver.resolve(item) == .embed(URL(string: "https://www.youtube.com/embed/abc123")!))
}

@Test func vimeoURLResolvesToEmbed() {
    let item = makeItem(type: .url, url: "https://vimeo.com/123456789")
    #expect(MediaResolver.resolve(item) == .embed(URL(string: "https://player.vimeo.com/video/123456789")!))
}

@Test func vimeoChannelURLDoesNotResolveToEmbed() {
    // /channels/staff is not a video — must not produce a broken
    // player URL.
    let item = makeItem(type: .url, url: "https://vimeo.com/channels/staff")
    #expect(MediaResolver.resolve(item) == .none)
}
