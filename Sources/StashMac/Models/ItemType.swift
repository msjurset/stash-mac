import SwiftUI

enum ItemType: String, Codable, CaseIterable, Identifiable {
    case link
    case snippet
    case file
    case image
    case email

    var id: String { rawValue }

    var label: String {
        switch self {
        case .link: "Links"
        case .snippet: "Snippets"
        case .file: "Files"
        case .image: "Images"
        case .email: "Emails"
        }
    }

    var icon: String {
        switch self {
        case .link: "link"
        case .snippet: "doc.text"
        case .file: "doc"
        case .image: "photo"
        case .email: "envelope"
        }
    }
}
