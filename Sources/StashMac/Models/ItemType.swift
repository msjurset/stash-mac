import SwiftUI

enum ItemType: String, Codable, CaseIterable, Identifiable {
    case url = "link" // stored as "link" in DB; displayed as "URL"
    case snippet
    case file
    case image
    case audio
    case email

    var id: String { rawValue }

    var label: String {
        switch self {
        case .url: "URLs"
        case .snippet: "Snippets"
        case .file: "Files"
        case .image: "Images"
        case .audio: "Audio"
        case .email: "Emails"
        }
    }

    var icon: String {
        switch self {
        case .url: "globe"
        case .snippet: "doc.text"
        case .file: "doc"
        case .image: "photo"
        case .audio: "waveform"
        case .email: "envelope"
        }
    }

    var tooltip: String {
        switch self {
        case .url: "Web pages, articles, and external links"
        case .snippet: "Text snippets, code fragments, and notes"
        case .file: "Documents, PDFs, and generic files"
        case .image: "Photos, screenshots, and visual assets"
        case .audio: "Voice memos, recordings, and audio files"
        case .email: "Saved emails and correspondence"
        }
    }
}
