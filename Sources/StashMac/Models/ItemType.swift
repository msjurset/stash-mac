import SwiftUI

enum ItemType: String, Codable, CaseIterable, Identifiable {
    case url = "link" // stored as "link" in DB; displayed as "URL"
    case snippet
    case file
    case image
    case email

    var id: String { rawValue }

    var label: String {
        switch self {
        case .url: "URLs"
        case .snippet: "Snippets"
        case .file: "Files"
        case .image: "Images"
        case .email: "Emails"
        }
    }

    var icon: String {
        switch self {
        case .url: "globe"
        case .snippet: "doc.text"
        case .file: "doc"
        case .image: "photo"
        case .email: "envelope"
        }
    }
}
