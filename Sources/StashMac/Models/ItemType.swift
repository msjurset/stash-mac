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
        case .url: "Web pages, articles, bookmarks, and external links"
        case .snippet: "Text snippets, code fragments, notes, and quick thoughts"
        case .file: "PDFs, spreadsheets, presentations, and generic documents"
        case .image: "Photos, screenshots, diagrams, and other visual assets"
        case .audio: "Voice memos, meetings, lectures, and other audio recordings"
        case .email: "Saved emails, correspondence, and newsletters"
        }
    }
}
