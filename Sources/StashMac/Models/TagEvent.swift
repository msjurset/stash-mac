import Foundation

/// Mirror of `internal/audit.TagEvent` from gostash. One row per
/// manual tag mutation written by the user via `stash edit` or
/// `stash bulk tag` (or any Mac UI surface that routes through them).
///
/// The decoder uses `.convertFromSnakeCase`, so JSON `item_url` arrives
/// as `itemUrl` — bare camelCase property names are correct here.
struct TagEvent: Codable, Hashable, Identifiable {
    var timestamp: Date
    var action: String          // "add" | "remove"
    var tag: String
    var itemId: String
    var itemType: String?
    var itemUrl: String?
    var itemDomain: String?
    var source: String?

    /// Synthetic id since `TagEvent` has no DB primary key — combine
    /// timestamp + item + action so SwiftUI ForEach has something stable
    /// even when several events share the same item.
    var id: String {
        "\(timestamp.timeIntervalSince1970)-\(itemId)-\(action)-\(tag)"
    }
}
