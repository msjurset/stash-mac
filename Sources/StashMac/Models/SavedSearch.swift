import Foundation

struct SavedSearch: Codable, Identifiable, Hashable {
    var id: Int64
    var name: String
    var query: String
    var filter: SearchFilter
    /// True for Smart Collections — saved searches that auto-refresh
    /// on `.stashDidIngest` and render in their own sidebar section.
    /// Static (false) saved searches keep the original click-to-run
    /// snapshot semantics. Optional decode keeps old DBs without the
    /// `live` column safe to load.
    var live: Bool = false

    enum CodingKeys: String, CodingKey {
        case id, name, query, filter, live
    }

    init(id: Int64, name: String, query: String, filter: SearchFilter, live: Bool = false) {
        self.id = id
        self.name = name
        self.query = query
        self.filter = filter
        self.live = live
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(Int64.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.query = try c.decode(String.self, forKey: .query)
        self.filter = try c.decode(SearchFilter.self, forKey: .filter)
        self.live = try c.decodeIfPresent(Bool.self, forKey: .live) ?? false
    }

    struct SearchFilter: Codable, Hashable {
        var type: String?
        var tags: [String]?
        var excludeTags: [String]?
        var untagged: Bool?
        var collection: String?
        var recent: String?
        var regex: String?
        var limit: Int?

        enum CodingKeys: String, CodingKey {
            case type, tags
            case excludeTags = "exclude_tags"
            case untagged
            case collection
            case recent
            case regex
            case limit
        }

        init(
            type: String? = nil,
            tags: [String]? = nil,
            excludeTags: [String]? = nil,
            untagged: Bool? = nil,
            collection: String? = nil,
            recent: String? = nil,
            regex: String? = nil,
            limit: Int? = nil
        ) {
            self.type = type
            self.tags = tags
            self.excludeTags = excludeTags
            self.untagged = untagged
            self.collection = collection
            self.recent = recent
            self.regex = regex
            self.limit = limit
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.type = try c.decodeIfPresent(String.self, forKey: .type)
            self.tags = try c.decodeIfPresent([String].self, forKey: .tags)
            self.excludeTags = try c.decodeIfPresent([String].self, forKey: .excludeTags)
            self.untagged = try c.decodeIfPresent(Bool.self, forKey: .untagged)
            self.collection = try c.decodeIfPresent(String.self, forKey: .collection)
            self.recent = try c.decodeIfPresent(String.self, forKey: .recent)
            self.regex = try c.decodeIfPresent(String.self, forKey: .regex)
            self.limit = try c.decodeIfPresent(Int.self, forKey: .limit)
        }
    }

    var summary: String {
        var parts: [String] = []
        if !query.isEmpty { parts.append(query) }
        if let t = filter.type, !t.isEmpty { parts.append("type:\(t)") }
        if let tags = filter.tags {
            for tag in tags { parts.append("tag:\(tag)") }
        }
        if let xs = filter.excludeTags {
            for tag in xs { parts.append("-tag:\(tag)") }
        }
        if filter.untagged == true { parts.append("untagged") }
        if let c = filter.collection, !c.isEmpty { parts.append("col:\(c)") }
        if let r = filter.recent, !r.isEmpty { parts.append("recent:\(r)") }
        if let rx = filter.regex, !rx.isEmpty { parts.append("re:\(rx)") }
        return parts.joined(separator: " ")
    }
}
