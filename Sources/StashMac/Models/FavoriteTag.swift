import Foundation

/// Canonical name of the "favorite" / "starred" tag. Defined in
/// one place so a future rename (e.g. `fav` → `star`) is a
/// single-line change and every UI surface — toolbar star
/// button, list-row indicator, smart-collection filter — picks
/// it up automatically.
///
/// Why a tag rather than a `favorite: Bool` column: tags
/// compose with the existing search / smart-collection / filter
/// stack for free, the user keeps a single mental model for
/// "what I marked," and the DB stays migration-free. The only
/// trade-off is a fav-cardinality entry in the tag cloud,
/// which is cosmetic and can be hidden by convention from the
/// "Top tags" view if it ever grows enough to clutter.
enum FavoriteTag {
    static let name = "fav"
}
