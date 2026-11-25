import Foundation

/// Structured recipe metadata extracted from recipe websites, schema.org/Recipe JSON-LD,
/// microdata, or text parsing.
struct RecipeData: Codable, Equatable, Hashable {
    var title: String
    var description: String?
    var imageURL: String?
    var author: String?
    var sourceURL: String?
    var yield: String?
    var prepTime: String?
    var cookTime: String?
    var totalTime: String?
    var category: String?
    var cuisine: String?
    var ingredients: [RecipeIngredient]
    var instructions: [RecipeInstruction]
    var nutrition: [String: String]?
    var cookHistory: [RecipeCookEntry]

    enum CodingKeys: String, CodingKey {
        case title
        case description
        case imageURL = "imageUrl"
        case author
        case sourceURL = "sourceUrl"
        case yield
        case prepTime
        case cookTime
        case totalTime
        case category
        case cuisine
        case ingredients
        case instructions
        case nutrition
        case cookHistory
    }

    init(
        title: String,
        description: String? = nil,
        imageURL: String? = nil,
        author: String? = nil,
        sourceURL: String? = nil,
        yield: String? = nil,
        prepTime: String? = nil,
        cookTime: String? = nil,
        totalTime: String? = nil,
        category: String? = nil,
        cuisine: String? = nil,
        ingredients: [RecipeIngredient] = [],
        instructions: [RecipeInstruction] = [],
        nutrition: [String: String]? = nil,
        cookHistory: [RecipeCookEntry] = []
    ) {
        self.title = title
        self.description = description
        self.imageURL = imageURL
        self.author = author
        self.sourceURL = sourceURL
        self.yield = yield
        self.prepTime = prepTime
        self.cookTime = cookTime
        self.totalTime = totalTime
        self.category = category
        self.cuisine = cuisine
        self.ingredients = ingredients
        self.instructions = instructions
        self.nutrition = nutrition
        self.cookHistory = cookHistory
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.title = (try? container.decodeIfPresent(String.self, forKey: .title)) ?? "Recipe"
        self.description = try? container.decodeIfPresent(String.self, forKey: .description)
        self.imageURL = try? container.decodeIfPresent(String.self, forKey: .imageURL)
        self.author = try? container.decodeIfPresent(String.self, forKey: .author)
        self.sourceURL = try? container.decodeIfPresent(String.self, forKey: .sourceURL)
        self.yield = try? container.decodeIfPresent(String.self, forKey: .yield)
        self.prepTime = try? container.decodeIfPresent(String.self, forKey: .prepTime)
        self.cookTime = try? container.decodeIfPresent(String.self, forKey: .cookTime)
        self.totalTime = try? container.decodeIfPresent(String.self, forKey: .totalTime)
        self.category = try? container.decodeIfPresent(String.self, forKey: .category)
        self.cuisine = try? container.decodeIfPresent(String.self, forKey: .cuisine)
        self.ingredients = (try? container.decodeIfPresent([RecipeIngredient].self, forKey: .ingredients)) ?? []
        let rawInstructions = (try? container.decodeIfPresent([RecipeInstruction].self, forKey: .instructions)) ?? []
        self.instructions = rawInstructions.enumerated().map { idx, step in
            var copy = step
            if copy.stepNumber <= 0 || (idx > 0 && copy.stepNumber == 1) {
                copy.stepNumber = idx + 1
            }
            return copy
        }
        self.nutrition = try? container.decodeIfPresent([String: String].self, forKey: .nutrition)
        self.cookHistory = (try? container.decodeIfPresent([RecipeCookEntry].self, forKey: .cookHistory)) ?? []
    }

    /// Formats ingredients into a clean, plaintext list suitable for clipboard export.
    var formattedIngredientsPlaintext: String {
        var lines: [String] = []
        var currentSection: String? = nil
        for item in ingredients {
            if let sec = item.section, !sec.isEmpty, sec != currentSection {
                currentSection = sec
                if !lines.isEmpty { lines.append("") }
                lines.append("[\(sec)]")
            }
            lines.append("• \(item.text)")
        }
        return lines.joined(separator: "\n")
    }

    /// Formats full recipe as clean Markdown (title, meta, ingredients, instructions).
    var formattedMarkdown: String {
        var parts: [String] = []
        parts.append("# \(title)")
        if let desc = description, !desc.isEmpty {
            parts.append(desc)
        }

        var meta: [String] = []
        if let y = yield, !y.isEmpty { meta.append("**Yield:** \(y)") }
        if let pt = prepTime, !pt.isEmpty { meta.append("**Prep:** \(pt)") }
        if let ct = cookTime, !ct.isEmpty { meta.append("**Cook:** \(ct)") }
        if let tt = totalTime, !tt.isEmpty { meta.append("**Total:** \(tt)") }
        if let c = cuisine, !c.isEmpty { meta.append("**Cuisine:** \(c)") }
        if let cat = category, !cat.isEmpty { meta.append("**Category:** \(cat)") }
        if !meta.isEmpty {
            parts.append(meta.joined(separator: " | "))
        }

        parts.append("## Ingredients")
        parts.append(formattedIngredientsPlaintext)

        parts.append("## Instructions")
        var currentSection: String? = nil
        for step in instructions {
            if let sec = step.section, !sec.isEmpty, sec != currentSection {
                currentSection = sec
                parts.append("\n### \(sec)")
            }
            let prefix = step.displayTitle.map { "**\($0)**: " } ?? ""
            parts.append("\(step.stepNumber). \(prefix)\(step.text)")
        }

        if let nut = nutrition, !nut.isEmpty {
            parts.append("## Nutrition")
            let lines = nut.map { "**\($0.key.capitalized):** \($0.value)" }
            parts.append(lines.joined(separator: " · "))
        }

        if !cookHistory.isEmpty {
            parts.append("## Cook Log (\(cookHistory.count))")
            let logLines = cookHistory.map { entry -> String in
                var line = "- **\(entry.formattedDate)**"
                if let stars = entry.formattedStars {
                    line += " \(stars)"
                }
                if let note = entry.note, !note.isEmpty {
                    line += " — \(note)"
                }
                return line
            }
            parts.append(logLines.joined(separator: "\n"))
        }

        return parts.joined(separator: "\n\n")
    }
}

/// A single logged cooking session for a recipe.
struct RecipeCookEntry: Codable, Equatable, Hashable, Identifiable {
    var id: String { "\(cookedAt)-\(rating ?? 0)-\(note ?? "")" }
    var cookedAt: String
    var rating: Int?
    var note: String?

    enum CodingKeys: String, CodingKey {
        case cookedAt
        case rating
        case note
    }

    init(cookedAt: String, rating: Int? = nil, note: String? = nil) {
        self.cookedAt = cookedAt
        self.rating = rating
        self.note = note
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.cookedAt = (try? container.decodeIfPresent(String.self, forKey: .cookedAt)) ?? ""
        self.rating = try? container.decodeIfPresent(Int.self, forKey: .rating)
        self.note = try? container.decodeIfPresent(String.self, forKey: .note)
    }

    var parsedDate: Date? {
        let frac = ISO8601DateFormatter()
        frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = frac.date(from: cookedAt) { return d }
        let std = ISO8601DateFormatter()
        std.formatOptions = [.withInternetDateTime]
        return std.date(from: cookedAt)
    }

    var formattedDate: String {
        if let d = parsedDate {
            return d.formatted(date: .abbreviated, time: .omitted)
        }
        return cookedAt
    }

    var formattedStars: String? {
        guard let r = rating, r >= 1 else { return nil }
        let clamped = min(5, max(1, r))
        return String(repeating: "★", count: clamped) + String(repeating: "☆", count: 5 - clamped)
    }
}

/// A single ingredient item in a recipe.
struct RecipeIngredient: Codable, Equatable, Hashable, Identifiable {
    var id: String { "\(section ?? ""):\(text)" }
    var text: String
    var section: String?

    enum CodingKeys: String, CodingKey {
        case text
        case section
    }

    init(text: String, section: String? = nil) {
        self.text = text
        self.section = section
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.text = (try? container.decodeIfPresent(String.self, forKey: .text)) ?? ""
        self.section = try? container.decodeIfPresent(String.self, forKey: .section)
    }
}

/// A single step in a recipe's instructions.
struct RecipeInstruction: Codable, Equatable, Hashable, Identifiable {
    var id: Int { stepNumber }
    var stepNumber: Int
    var title: String?
    var text: String
    var section: String?

    enum CodingKeys: String, CodingKey {
        case stepNumber
        case title
        case text
        case section
    }

    init(stepNumber: Int, title: String? = nil, text: String, section: String? = nil) {
        self.stepNumber = stepNumber
        self.title = title
        self.text = text
        self.section = section
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.stepNumber = (try? container.decodeIfPresent(Int.self, forKey: .stepNumber)) ?? 1
        self.title = try? container.decodeIfPresent(String.self, forKey: .title)
        self.text = (try? container.decodeIfPresent(String.self, forKey: .text)) ?? ""
        self.section = try? container.decodeIfPresent(String.self, forKey: .section)
    }

    /// Returns a non-redundant step title suitable for UI display and TTS speech,
    /// or `nil` if the title is empty, a generic `"Step N"` label, or already
    /// duplicated at the beginning of `text`.
    var displayTitle: String? {
        guard let raw = title?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        if raw.range(of: #"^(?:step\s*#?\s*\d+|\d+)[\s:.\-)*]*$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return nil
        }
        if raw.caseInsensitiveCompare("Step \(stepNumber)") == .orderedSame {
            return nil
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix(raw.lowercased()) {
            return nil
        }
        return raw
    }
}
