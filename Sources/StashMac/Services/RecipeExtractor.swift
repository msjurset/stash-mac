import Foundation

/// Fast, deterministic, zero-cost recipe extractor that extracts structured
/// recipe data from Schema.org JSON-LD, Microdata, and recipe blogs.
/// Also provides an optional AI fallback for unstructured texts.
enum RecipeExtractor {

    // MARK: - Public API

    /// Fetches the webpage at `url` and extracts structured recipe data if present.
    static func extract(from url: URL) async throws -> RecipeData? {
        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            return nil
        }

        let html = String(decoding: data, as: UTF8.self)
        return extract(html: html, sourceURL: url.absoluteString)
    }

    /// Extracts structured recipe data from HTML source text.
    static func extract(html: String, sourceURL: String? = nil) -> RecipeData? {
        // 1. Try JSON-LD (covers ~95% of recipe websites)
        if let recipe = extractJSONLD(from: html, sourceURL: sourceURL) {
            return recipe
        }

        // 2. Try Microdata / semantic HTML
        if let recipe = extractMicrodata(from: html, sourceURL: sourceURL) {
            return recipe
        }

        // 3. Try HTML heuristic extraction (WP Recipe Maker, Tasty Recipes, Create)
        if let recipe = extractHeuristics(from: html, sourceURL: sourceURL) {
            return recipe
        }

        // 4. Try structured plaintext heuristic extraction (on-device NLP/pattern parser)
        let stripped = html
            .replacingOccurrences(of: "<script[^>]*>.*?</script>", with: "\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<style[^>]*>.*?</style>", with: "\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<(?:br|p|div|li|h[1-6]|tr)[^>]*>", with: "\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        if let recipe = extractFromPlaintext(unescapeHTML(stripped), fallbackTitle: extractHTMLTitle(from: html), sourceURL: sourceURL) {
            return recipe
        }

        return nil
    }

    /// Extracts structured recipe data from plain text or Markdown (e.g. `extractedText` or `notes` on a StashItem)
    /// using on-device deterministic section and ingredient/step heuristics. Zero API cost.
    static func extractFromPlaintext(_ text: String, fallbackTitle: String? = nil, sourceURL: String? = nil) -> RecipeData? {
        let rawLines = text.components(separatedBy: .newlines)
        var lines: [String] = []
        for raw in rawLines {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                lines.append(trimmed)
            }
        }
        guard lines.count >= 3 else { return nil }

        enum Section {
            case preamble
            case ingredients
            case instructions
            case notes
        }

        var currentSection: Section = .preamble
        var currentSubSection: String? = nil
        var detectedTitle: String? = nil
        var hasExplicitHeadingTitle = false
        var descriptionLines: [String] = []
        var yield: String? = nil
        var prepTime: String? = nil
        var cookTime: String? = nil
        var totalTime: String? = nil
        var ingredients: [RecipeIngredient] = []
        var instructionStrings: [(text: String, section: String?)] = []

        let ingHeaderRegex = try? NSRegularExpression(
            pattern: #"^(?:#+\s*|\*\*|__)?(?:ingredients(?:\s*(?:\([^)]*\)|for\b[^:]*|-.*))?|what you(?:'ll)? need(?:\s*\([^)]*\))?|shopping list(?:\s*\([^)]*\))?)(?:\*\*|__)?\s*:?\s*$"#,
            options: .caseInsensitive
        )
        let instHeaderRegex = try? NSRegularExpression(
            pattern: #"^(?:#+\s*|\*\*|__)?(?:(?:quick|easy|simple|step-by-step)\s+)?(?:instructions|directions|method|preparation|steps|procedure|how to make(?:\s+[^:]*)?)(?:\s*\([^)]*\))?(?:\*\*|__)?\s*:?\s*$"#,
            options: .caseInsensitive
        )
        let stopHeaderRegex = try? NSRegularExpression(
            pattern: #"^(?:#+\s*|\*\*|__)?(?:notes|recipe notes|chef'?s notes|nutrition(?:\s+facts|\s+info(?:rmation)?)?|serving ideas|serving suggestions|ways to serve|to serve|tips(?:\s*(?:and|&|/)\s*variations)?|variations|substitutions|storage|make[- ]ahead|close\s*/\s*call to action|call to action|video|comments|leave a (?:reply|comment)|did you make this)(?:\*\*|__)?\s*:?\s*$"#,
            options: .caseInsensitive
        )
        let numberedStepRegex = try? NSRegularExpression(
            pattern: #"^(?:step\s*\d+[\s:.\-)+]+|\d+\s*[.\)\-:]\s*)\S+"#,
            options: .caseInsensitive
        )
        let measuredIngRegex = try? NSRegularExpression(
            pattern: #"^(?:[-*•▪◦▢]\s*)?(?:(?:\d+\s+)?\d+/\d+|\d+(?:\.\d+)?(?:\s*[-–]\s*\d+(?:\.\d+)?)?|[½⅓⅔¼¾⅛⅜⅝⅞]+|\d+\s*[½⅓⅔¼¾⅛⅜⅝⅞])\s*(?:\([^)]+\)\s*)?(?:cups?|c\.|tbsp\.?|tablespoons?|tsp\.?|teaspoons?|oz\.?|ounces?|lbs?\.?|pounds?|g|grams?|kg|ml|l|liters?|pinch(?:es)?|dash(?:es)?|cloves?|cans?|slices?|pieces?|stalks?|bunches?|heads?|sprigs?|packages?|pkgs?|jars?|bottles?|boxes?|bags?|sticks?|ears?|fillets?|breasts?|thighs?|medium|large|small|fresh|whole)\b"#,
            options: .caseInsensitive
        )
        let saltOrOptionalRegex = try? NSRegularExpression(
            pattern: #"^(?:[-*•▪◦▢]\s*)?(?:salt(?:\s+and\s+(?:black\s+)?pepper)?\b|optional\s*:|to taste\b)"#,
            options: .caseInsensitive
        )

        for line in lines {
            let cleanHeaderCandidate = line.trimmingCharacters(in: CharacterSet(charactersIn: "#*_-•▪◦▢▫: \t"))
            let nsLine = NSRange(line.startIndex..<line.endIndex, in: line)

            if let r = ingHeaderRegex, r.firstMatch(in: line, range: nsLine) != nil {
                currentSection = .ingredients
                currentSubSection = nil
                continue
            }
            if let r = instHeaderRegex, r.firstMatch(in: line, range: nsLine) != nil {
                currentSection = .instructions
                currentSubSection = nil
                continue
            }
            if let r = stopHeaderRegex, r.firstMatch(in: line, range: nsLine) != nil {
                if !ingredients.isEmpty && !instructionStrings.isEmpty {
                    currentSection = .notes
                    continue
                }
            }

            // Metadata line detection (Prep Time, Cook Time, Total Time, Yield/Servings)
            let lower = cleanHeaderCandidate.lowercased()
            if lower.hasPrefix("prep time") || lower.hasPrefix("prep:") {
                if let val = extractMetaColonValue(from: line) { prepTime = val; continue }
            } else if lower.hasPrefix("cook time") || lower.hasPrefix("cook:") {
                if let val = extractMetaColonValue(from: line) { cookTime = val; continue }
            } else if lower.hasPrefix("total time") || lower.hasPrefix("total:") {
                if let val = extractMetaColonValue(from: line) { totalTime = val; continue }
            } else if lower.hasPrefix("servings") || lower.hasPrefix("yield") || lower.hasPrefix("serves") || lower.hasPrefix("makes") {
                if let val = extractMetaColonValue(from: line) { yield = val; continue }
            }

            switch currentSection {
            case .preamble:
                if line.hasPrefix("#") && !hasExplicitHeadingTitle && !cleanHeaderCandidate.isEmpty {
                    detectedTitle = cleanHeaderCandidate
                    hasExplicitHeadingTitle = true
                } else if detectedTitle == nil && line.count <= 70 && !line.hasSuffix(".") && !line.hasSuffix("!") && !line.hasPrefix("#") {
                    detectedTitle = cleanHeaderCandidate
                } else if descriptionLines.count < 2 && line.count > 20 && line.count < 280 && !line.hasPrefix("#") {
                    descriptionLines.append(cleanText(line))
                }
            case .ingredients:
                // If numbered steps begin directly after bulleted ingredients without an explicit instructions header, switch to instructions
                if ingredients.count >= 2,
                   let stepRe = numberedStepRegex, stepRe.firstMatch(in: line, range: nsLine) != nil,
                   (measuredIngRegex?.firstMatch(in: line, range: nsLine) == nil) {
                    currentSection = .instructions
                    currentSubSection = nil
                    let stepText = stripStepNumberPrefix(
                        line.replacingOccurrences(of: #"^[-*•▪◦▢]\s*"#, with: "", options: .regularExpression)
                    )
                    if !stepText.isEmpty {
                        instructionStrings.append((text: stepText, section: nil))
                    }
                    continue
                }
                let lowerLine = line.lowercased()
                if (lowerLine.hasPrefix("for ") || line.hasSuffix(":") || line.hasPrefix("###"))
                    && line.count < 45 && !line.contains(where: { $0.isNumber }) && !lowerLine.hasPrefix("optional:") {
                    currentSubSection = cleanHeaderCandidate
                    continue
                }
                let itemText = line.replacingOccurrences(of: #"^(?:[-*•▪◦▢]|\[\s*[xX]?\s*\])\s*"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !itemText.isEmpty && itemText.count < 200 {
                    ingredients.append(RecipeIngredient(text: itemText, section: currentSubSection))
                }
            case .instructions:
                let lowerLine = line.lowercased()
                if (lowerLine.hasPrefix("for ") || (line.hasSuffix(":") && line.count < 40) || line.hasPrefix("###"))
                    && !line.contains(where: { $0.isNumber }) {
                    currentSubSection = cleanHeaderCandidate
                    continue
                }
                let stepText = stripStepNumberPrefix(
                    line.replacingOccurrences(of: #"^[-*•▪◦▢]\s*"#, with: "", options: .regularExpression)
                )
                if !stepText.isEmpty {
                    instructionStrings.append((text: stepText, section: currentSubSection))
                }
            case .notes:
                break
            }
        }

        // Fallback for headerless recipes (e.g., TikTok/YouTube video notes with measured/bulleted ingredients + numbered steps)
        if ingredients.count < 2 || instructionStrings.isEmpty {
            var fallbackIngs: [RecipeIngredient] = []
            var fallbackSteps: [(text: String, section: String?)] = []
            var seenStep = false
            for line in lines {
                let nsLine = NSRange(line.startIndex..<line.endIndex, in: line)
                if let stopRe = stopHeaderRegex, stopRe.firstMatch(in: line, range: nsLine) != nil,
                   fallbackIngs.count >= 2 && !fallbackSteps.isEmpty {
                    break
                }
                let isNumberedStep = numberedStepRegex?.firstMatch(in: line, range: nsLine) != nil
                let isMeasuredIng = measuredIngRegex?.firstMatch(in: line, range: nsLine) != nil
                let isSaltOrOpt = saltOrOptionalRegex?.firstMatch(in: line, range: nsLine) != nil
                if isNumberedStep && (!isMeasuredIng || seenStep || fallbackIngs.count >= 2) {
                    seenStep = true
                    let stepText = stripStepNumberPrefix(
                        line.replacingOccurrences(of: #"^[-*•▪◦▢]\s*"#, with: "", options: .regularExpression)
                    )
                    if stepText.count >= 8 {
                        fallbackSteps.append((text: stepText, section: nil))
                    }
                    continue
                }
                if !seenStep && (isMeasuredIng || isSaltOrOpt) {
                    let itemText = line.replacingOccurrences(of: #"^(?:[-*•▪◦▢]|\[\s*[xX]?\s*\])\s*"#, with: "", options: .regularExpression)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !itemText.isEmpty && itemText.count < 180 {
                        fallbackIngs.append(RecipeIngredient(text: itemText, section: nil))
                    }
                }
            }
            if fallbackIngs.count >= 2 && !fallbackSteps.isEmpty {
                ingredients = fallbackIngs
                instructionStrings = fallbackSteps
            }
        }

        guard !ingredients.isEmpty, !instructionStrings.isEmpty else {
            return nil
        }

        let instructions = instructionStrings.enumerated().map { idx, item in
            RecipeInstruction(
                stepNumber: idx + 1,
                title: nil,
                text: item.text,
                section: item.section
            )
        }

        let trimmedFallback = fallbackTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalTitle: String
        if let dt = detectedTitle, !dt.isEmpty {
            finalTitle = dt
        } else if let fb = trimmedFallback, !fb.isEmpty {
            finalTitle = fb
        } else {
            finalTitle = "Recipe"
        }
        let desc = descriptionLines.isEmpty ? nil : descriptionLines.joined(separator: " ")

        return RecipeData(
            title: finalTitle,
            description: desc,
            imageURL: nil,
            author: nil,
            sourceURL: sourceURL,
            yield: yield,
            prepTime: prepTime,
            cookTime: cookTime,
            totalTime: totalTime,
            category: nil,
            cuisine: nil,
            ingredients: ingredients,
            instructions: instructions,
            nutrition: nil
        )
    }

    /// Optional AI fallback for extracting a recipe from unstructured text or notes when deterministic
    /// extraction finds no schema or clear headings. Uses a single text-only call to the active AI provider
    /// (or `stash` CLI AI) with a strict token cap on input to keep costs under $0.001.
    @MainActor
    static func extractWithAI(
        text: String,
        fallbackTitle: String?,
        sourceURL: String?,
        prefs: AIPrefsStore
    ) async throws -> RecipeData? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let cappedInput = String(trimmed.prefix(12_000))

        let prompt = """
        Extract the recipe from the following text into a single JSON object. Strip all blog preamble, life stories, ads, andunrelated commentary.
        Return ONLY valid JSON (no markdown code fences) matching this exact structure:
        {
          "title": "Recipe Title",
          "description": "Short 1-2 sentence appetizing summary",
          "yield": "e.g. 4 servings",
          "prep_time": "e.g. 15 mins",
          "cook_time": "e.g. 30 mins",
          "total_time": "e.g. 45 mins",
          "category": "e.g. Dinner",
          "cuisine": "e.g. Italian",
          "ingredients": [
            {"text": "2 cups flour", "section": null}
          ],
          "instructions": [
            {"step_number": 1, "title": "Mix dry ingredients", "text": "Whisk together the flour and salt.", "section": null}
          ]
        }

        SOURCE TEXT:
        \(cappedInput)
        """

        guard prefs.hasKey else { return nil }
        let resolvedKey = try await AIKeyResolver.resolve(prefs.apiKey)
        let resolvedPaidKey = prefs.hasPaidKey ? try? await AIKeyResolver.resolve(prefs.paidApiKey) : nil
        let rawJSON: String

        switch prefs.activeID {
        case .gemini:
            rawJSON = try await generateGeminiText(
                apiKey: resolvedKey,
                paidApiKey: resolvedPaidKey,
                isFailoverApproved: prefs.isFailoverApproved,
                prompt: prompt
            )
        case .claude:
            rawJSON = try await generateClaudeText(apiKey: resolvedKey, prompt: prompt)
        }

        let cleanedJSON = rawJSON
            .replacingOccurrences(of: #"^```(?:json)?\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s*```$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleanedJSON.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        if var decoded = try? decoder.decode(RecipeData.self, from: data) {
            if decoded.title.isEmpty, let ft = fallbackTitle, !ft.isEmpty {
                decoded.title = ft
            }
            if decoded.sourceURL == nil {
                decoded.sourceURL = sourceURL
            }
            return decoded
        }
        return nil
    }

    private static func generateGeminiText(
        apiKey: String,
        paidApiKey: String?,
        isFailoverApproved: Bool,
        prompt: String
    ) async throws -> String {
        do {
            return try await postGeminiText(apiKey: apiKey, model: "gemini-2.5-flash-lite", prompt: prompt)
        } catch let err as GeminiProvider.GeminiError {
            if case .http(let status, let body) = err {
                let lower = body.lowercased()
                let isFailoverCandidate =
                    (status == 429 && (lower.contains("quota") || lower.contains("free_tier") || lower.contains("resource_exhausted") || lower.contains("billing"))) ||
                    (status == 503 && (lower.contains("unavailable") || lower.contains("high demand")))
                if isFailoverCandidate, let paidKey = paidApiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !paidKey.isEmpty {
                    if isFailoverApproved {
                        return try await postGeminiText(apiKey: paidKey, model: "gemini-2.5-flash-lite", prompt: prompt)
                    } else {
                        throw GeminiFailoverApprovalRequiredError(operation: "recipe_extract")
                    }
                }
            }
            throw err
        }
    }

    private static func postGeminiText(apiKey: String, model: String, prompt: String) async throws -> String {
        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)"
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        var req = URLRequest(url: url, timeoutInterval: 25)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "contents": [
                ["parts": [["text": prompt]]]
            ]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(status) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw GeminiProvider.GeminiError.http(status: status, body: bodyText)
        }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let usage = json["usageMetadata"] as? [String: Any] {
                let promptTokens = usage["promptTokenCount"] as? Int
                let candidateTokens = usage["candidatesTokenCount"] as? Int
                await MainActor.run {
                    GeminiUsageStore.shared.record(
                        model: model,
                        promptTokens: promptTokens,
                        candidateTokens: candidateTokens
                    )
                }
            }
            if let candidates = json["candidates"] as? [[String: Any]],
               let content = candidates.first?["content"] as? [String: Any],
               let parts = content["parts"] as? [[String: Any]],
               let text = parts.first?["text"] as? String {
                return text
            }
        }
        return ""
    }

    private static func generateClaudeText(apiKey: String, prompt: String) async throws -> String {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else { throw URLError(.badURL) }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let payload: [String: Any] = [
            "model": "claude-sonnet-4-6",
            "max_tokens": 2048,
            "messages": [
                ["role": "user", "content": prompt]
            ]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let content = json["content"] as? [[String: Any]],
           let text = content.first?["text"] as? String {
            return text
        }
        return ""
    }

    private static func extractHTMLTitle(from html: String) -> String? {
        if let match = firstRegexMatch(pattern: #"<title[^>]*>(.*?)</title>"#, in: html) {
            let cleaned = cleanText(match)
            return cleaned.isEmpty ? nil : cleaned
        }
        return nil
    }

    private static func extractMetaColonValue(from line: String) -> String? {
        guard let colonIdx = line.firstIndex(of: ":") else { return nil }
        let after = line[line.index(after: colonIdx)...]
            .trimmingCharacters(in: CharacterSet(charactersIn: "*_ \t"))
        return after.isEmpty ? nil : after
    }

    // MARK: - JSON-LD Extraction

    /// Extracts recipe from `<script type="application/ld+json">` blocks.
    static func extractJSONLD(from html: String, sourceURL: String? = nil) -> RecipeData? {
        let pattern = #"<script[^>]*type=[\"']application/ld\+json[\"'][^>]*>(.*?)</script>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) else {
            return nil
        }

        let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = regex.matches(in: html, options: [], range: nsRange)

        for match in matches {
            guard match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: html) else { continue }
            let jsonString = html[range].trimmingCharacters(in: .whitespacesAndNewlines)

            let parsedJSON: Any? = {
                if let data = jsonString.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
                    return obj
                }
                let sanitized = sanitizeJSONControlCharacters(jsonString)
                if let data = sanitized.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
                    return obj
                }
                return nil
            }()

            if let json = parsedJSON,
               let recipeDict = findRecipeDictionary(in: json),
               let parsed = parseRecipeDictionary(recipeDict, sourceURL: sourceURL) {
                return parsed
            }
        }

        return nil
    }

    /// Escapes raw unescaped control characters (`\n`, `\r`, `\t`) that occur inside
    /// JSON string literals — a common bug in WordPress recipe plugins.
    static func sanitizeJSONControlCharacters(_ raw: String) -> String {
        var out = String()
        out.reserveCapacity(raw.count)
        var inString = false
        var escaped = false

        for ch in raw {
            if escaped {
                out.append(ch)
                escaped = false
                continue
            }
            if ch == "\\" && inString {
                out.append(ch)
                escaped = true
                continue
            }
            if ch == "\"" {
                inString.toggle()
                out.append(ch)
                continue
            }
            if inString {
                if ch == "\n" {
                    out.append("\\n")
                    continue
                } else if ch == "\r" {
                    out.append("\\r")
                    continue
                } else if ch == "\t" {
                    out.append("\\t")
                    continue
                }
            }
            out.append(ch)
        }
        return out
    }

    private static func findRecipeDictionary(in json: Any) -> [String: Any]? {
        if let dict = json as? [String: Any] {
            if isRecipeType(dict["@type"]) {
                return dict
            }
            if let graph = dict["@graph"] as? [Any] {
                for item in graph {
                    if let found = findRecipeDictionary(in: item) {
                        return found
                    }
                }
            }
            for (_, value) in dict {
                if let found = findRecipeDictionary(in: value) {
                    return found
                }
            }
        } else if let array = json as? [Any] {
            for item in array {
                if let found = findRecipeDictionary(in: item) {
                    return found
                }
            }
        }
        return nil
    }

    private static func isRecipeType(_ typeValue: Any?) -> Bool {
        guard let typeValue else { return false }
        if let typeStr = typeValue as? String {
            let lower = typeStr.lowercased()
            return lower == "recipe" || lower.hasSuffix("/recipe") || lower.hasSuffix("#recipe")
        } else if let typeArray = typeValue as? [String] {
            return typeArray.contains { isRecipeType($0) }
        }
        return false
    }

    private static func parseRecipeDictionary(_ dict: [String: Any], sourceURL: String?) -> RecipeData? {
        let rawTitle = (dict["name"] as? String) ?? (dict["headline"] as? String) ?? ""
        let title = cleanText(rawTitle)
        guard !title.isEmpty else { return nil }

        let description = (dict["description"] as? String).map { cleanText($0) }

        // Image (prefer full-size URL without -NNNxNNN WordPress thumbnail suffix when an array is given)
        var imageURL: String? = nil
        if let imgStr = dict["image"] as? String {
            imageURL = imgStr
        } else if let imgArray = dict["image"] as? [Any] {
            let strings = imgArray.compactMap { item -> String? in
                if let s = item as? String { return s }
                if let d = item as? [String: Any] { return (d["url"] as? String) ?? (d["contentUrl"] as? String) }
                return nil
            }
            imageURL = strings.last(where: { $0.range(of: #"-\d+x\d+\.[a-zA-Z]+$"#, options: .regularExpression) == nil })
                ?? strings.last
        } else if let imgDict = dict["image"] as? [String: Any] {
            imageURL = (imgDict["url"] as? String) ?? (imgDict["contentUrl"] as? String)
        }

        // Author
        var author: String? = nil
        if let authStr = dict["author"] as? String {
            author = cleanText(authStr)
        } else if let authDict = dict["author"] as? [String: Any] {
            author = (authDict["name"] as? String).map { cleanText($0) }
        } else if let authArray = dict["author"] as? [[String: Any]], let first = authArray.first {
            author = (first["name"] as? String).map { cleanText($0) }
        }

        // Yield / Servings
        var yield: String? = nil
        if let yStr = dict["recipeYield"] as? String {
            yield = cleanText(yStr)
        } else if let yArr = dict["recipeYield"] as? [Any] {
            let strings = yArr.compactMap { "\($0)".trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if let mostDescriptive = strings.max(by: { $0.count < $1.count }) {
                yield = cleanText(mostDescriptive)
            }
        } else if let yNum = dict["recipeYield"] as? NSNumber {
            yield = "\(yNum) servings"
        }

        // Durations
        let prepTime = parseDuration(dict["prepTime"])
        let cookTime = parseDuration(dict["cookTime"])
        let totalTime = parseDuration(dict["totalTime"])

        // Category & Cuisine
        let category = parseStringOrArray(dict["recipeCategory"])
        let cuisine = parseStringOrArray(dict["recipeCuisine"])

        // Ingredients
        var ingredients: [RecipeIngredient] = []
        if let ingList = dict["recipeIngredient"] as? [Any] {
            var currentSection: String? = nil
            for item in ingList {
                let raw = "\(item)".trimmingCharacters(in: .whitespacesAndNewlines)
                let cleaned = cleanText(raw)
                guard !cleaned.isEmpty else { continue }

                // Detect section headers within ingredients list (e.g. "For the crust:")
                if (cleaned.hasPrefix("For ") || cleaned.hasPrefix("For the ") || cleaned.hasSuffix(":") || cleaned.hasPrefix("##"))
                    && cleaned.count < 40 && !cleaned.contains(where: { $0.isNumber }) {
                    currentSection = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: ":#* -"))
                    continue
                }

                ingredients.append(RecipeIngredient(text: cleaned, section: currentSection))
            }
        }

        // Instructions
        var instructions: [RecipeInstruction] = []
        if let rawInst = dict["recipeInstructions"] {
            instructions = parseInstructions(rawInst)
        }

        guard !ingredients.isEmpty || !instructions.isEmpty else {
            return nil
        }

        // Nutrition
        var nutrition: [String: String]? = nil
        if let nutDict = dict["nutrition"] as? [String: Any] {
            var map: [String: String] = [:]
            let keys = [
                ("calories", "calories"),
                ("proteinContent", "protein"),
                ("carbohydrateContent", "carbs"),
                ("fatContent", "fat"),
                ("saturatedFatContent", "sat fat"),
                ("fiberContent", "fiber"),
                ("sugarContent", "sugar"),
                ("sodiumContent", "sodium"),
                ("servingSize", "serving size")
            ]
            for (schemaKey, label) in keys {
                if let val = nutDict[schemaKey] as? String {
                    let cleaned = cleanText(val)
                    if !cleaned.isEmpty { map[label] = cleaned }
                }
            }
            if !map.isEmpty { nutrition = map }
        }

        return RecipeData(
            title: title,
            description: description,
            imageURL: imageURL,
            author: author,
            sourceURL: sourceURL,
            yield: yield,
            prepTime: prepTime,
            cookTime: cookTime,
            totalTime: totalTime,
            category: category,
            cuisine: cuisine,
            ingredients: ingredients,
            instructions: instructions,
            nutrition: nutrition
        )
    }

    // MARK: - Instruction Parsing

    private static func parseInstructions(_ raw: Any) -> [RecipeInstruction] {
        var steps: [RecipeInstruction] = []
        var stepCounter = 1

        func addStep(text: String, title: String? = nil, section: String? = nil) {
            let cleaned = stripStepNumberPrefix(cleanText(text))
            guard !cleaned.isEmpty else { return }
            let rawTitle = title.map { cleanText($0) }?.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalTitle: String?
            if let t = rawTitle,
               !t.isEmpty,
               t.range(of: #"^(?:step\s*#?\s*\d+|\d+)[\s:.\-)*]*$"#, options: [.regularExpression, .caseInsensitive]) == nil,
               !cleaned.lowercased().hasPrefix(t.lowercased()) {
                finalTitle = t
            } else {
                finalTitle = nil
            }
            steps.append(RecipeInstruction(
                stepNumber: stepCounter,
                title: finalTitle,
                text: cleaned,
                section: section
            ))
            stepCounter += 1
        }

        if let str = raw as? String {
            // Multiline string
            let lines = str.components(separatedBy: .newlines)
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { addStep(text: trimmed) }
            }
        } else if let arr = raw as? [Any] {
            for item in arr {
                if let str = item as? String {
                    addStep(text: str)
                } else if let dict = item as? [String: Any] {
                    let type = (dict["@type"] as? String)?.lowercased() ?? ""
                    if type.contains("howtosection") {
                        let secName = (dict["name"] as? String).map { cleanText($0) }
                        if let subList = dict["itemListElement"] as? [Any] {
                            for sub in subList {
                                if let subDict = sub as? [String: Any] {
                                    let text = (subDict["text"] as? String) ?? (subDict["name"] as? String) ?? ""
                                    let title = subDict["name"] as? String
                                    addStep(text: text, title: title != text ? title : nil, section: secName)
                                } else if let subStr = sub as? String {
                                    addStep(text: subStr, section: secName)
                                }
                            }
                        }
                    } else {
                        // HowToStep
                        let text = (dict["text"] as? String) ?? (dict["name"] as? String) ?? ""
                        let title = dict["name"] as? String
                        addStep(text: text, title: (title != nil && title != text) ? title : nil)
                    }
                }
            }
        }

        return steps
    }

    // MARK: - Microdata Extraction Fallback

    static func extractMicrodata(from html: String, sourceURL: String? = nil) -> RecipeData? {
        guard html.lowercased().contains("schema.org/recipe") else { return nil }

        func extractItemProp(_ prop: String) -> String? {
            if let metaVal = firstRegexMatch(pattern: #"itemprop=[\"']\#(prop)[\"'][^>]*content=[\"']([^\"']+)[\"']"#, in: html) {
                let cleaned = cleanText(metaVal)
                if !cleaned.isEmpty { return cleaned }
            }
            if let metaValRev = firstRegexMatch(pattern: #"content=[\"']([^\"']+)[\"'][^>]*itemprop=[\"']\#(prop)[\"']"#, in: html) {
                let cleaned = cleanText(metaValRev)
                if !cleaned.isEmpty { return cleaned }
            }
            if let tagVal = firstRegexMatch(pattern: #"itemprop=[\"']\#(prop)[\"'][^>]*>(.*?)</"#, in: html) {
                let cleaned = cleanText(tagVal)
                if !cleaned.isEmpty { return cleaned }
            }
            return nil
        }

        // Find recipe title
        guard let title = extractItemProp("name"), !title.isEmpty else { return nil }
        let description = extractItemProp("description")
        let yield = extractItemProp("recipeYield")
        let prepTime = parseDuration(extractItemProp("prepTime"))
        let cookTime = parseDuration(extractItemProp("cookTime"))
        let totalTime = parseDuration(extractItemProp("totalTime"))

        // Ingredients
        let ingPattern = #"itemprop=[\"'](?:recipeIngredient|ingredients)[\"'][^>]*>(.*?)</"#
        let rawIngredients = allRegexMatches(pattern: ingPattern, in: html)
        let ingredients = rawIngredients.map { RecipeIngredient(text: cleanText($0), section: nil) }
            .filter { !$0.text.isEmpty }

        // Instructions: capture enclosing tag content (or individual itemprop="recipeInstructions" elements)
        let blockPattern = #"<([a-zA-Z0-9]+)[^>]*itemprop=[\"']recipeInstructions[\"'][^>]*>(.*?)</\1>"#
        var rawSteps: [String] = []
        if let regex = try? NSRegularExpression(pattern: blockPattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) {
            let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
            for match in regex.matches(in: html, range: nsRange) {
                if match.numberOfRanges > 2, let r = Range(match.range(at: 2), in: html) {
                    let inner = String(html[r])
                    let subItems = allRegexMatches(pattern: #"<(?:li|p)[^>]*>(.*?)</(?:li|p)>"#, in: inner)
                    if !subItems.isEmpty {
                        rawSteps.append(contentsOf: subItems)
                    } else {
                        let lines = inner.components(separatedBy: .newlines)
                        rawSteps.append(contentsOf: lines)
                    }
                }
            }
        }
        if rawSteps.isEmpty {
            let fallbackPattern = #"itemprop=[\"']recipeInstructions[\"'][^>]*>(.*?)</"#
            rawSteps = allRegexMatches(pattern: fallbackPattern, in: html)
        }

        var instructions: [RecipeInstruction] = []
        for step in rawSteps {
            let cleaned = stripStepNumberPrefix(cleanText(step))
            if !cleaned.isEmpty {
                instructions.append(RecipeInstruction(stepNumber: instructions.count + 1, title: nil, text: cleaned, section: nil))
            }
        }

        guard !ingredients.isEmpty || !instructions.isEmpty else { return nil }

        return RecipeData(
            title: title,
            description: description,
            imageURL: nil,
            author: nil,
            sourceURL: sourceURL,
            yield: yield,
            prepTime: prepTime,
            cookTime: cookTime,
            totalTime: totalTime,
            category: nil,
            cuisine: nil,
            ingredients: ingredients,
            instructions: instructions,
            nutrition: nil
        )
    }

    // MARK: - Heuristic Extraction Fallback

    static func extractHeuristics(from html: String, sourceURL: String? = nil) -> RecipeData? {
        // Look for WP Recipe Maker or Tasty Recipes container
        let isWPRM = html.contains("wprm-recipe")
        let isTasty = html.contains("tasty-recipes")
        guard isWPRM || isTasty else { return nil }

        let titlePattern = #"(?:wprm-recipe-name|tasty-recipes-title)[^>]*>(.*?)</"#
        let rawTitle = firstRegexMatch(pattern: titlePattern, in: html) ?? ""
        let title = cleanText(rawTitle)
        guard !title.isEmpty else { return nil }

        let descPattern = #"(?:wprm-recipe-summary|tasty-recipes-description)[^>]*>(.*?)</(?:div|p|span)>"#
        let description = firstRegexMatch(pattern: descPattern, in: html).map { cleanText($0) }.flatMap { $0.isEmpty ? nil : $0 }

        let ingPattern = #"<li[^>]*class=[\"'][^\"']*(?:wprm-recipe-ingredient|tasty-recipes-ingredients)[^\"']*[\"'][^>]*>(.*?)</li>"#
        var rawIngs = allRegexMatches(pattern: ingPattern, in: html)
        if rawIngs.isEmpty {
            if let container = firstRegexMatch(pattern: #"tasty-recipes-ingredients[^>]*>(.*?)</(?:div|ul)>"#, in: html) {
                rawIngs = allRegexMatches(pattern: #"<li[^>]*>(.*?)</li>"#, in: container)
            }
        }
        let ingredients = rawIngs.map { RecipeIngredient(text: cleanText($0), section: nil) }
            .filter { !$0.text.isEmpty }

        let instPattern = #"<(?:li|div|span)[^>]*class=[\"'][^\"']*(?:wprm-recipe-instruction-text|wprm-recipe-instruction|tasty-recipes-instructions)[^\"']*[\"'][^>]*>(.*?)</(?:li|div|span)>"#
        var rawSteps = allRegexMatches(pattern: instPattern, in: html)
        if rawSteps.isEmpty {
            if let container = firstRegexMatch(pattern: #"tasty-recipes-instructions[^>]*>(.*?)</(?:div|ol|ul)>"#, in: html) {
                rawSteps = allRegexMatches(pattern: #"<li[^>]*>(.*?)</li>"#, in: container)
            }
        }
        var instructions: [RecipeInstruction] = []
        for step in rawSteps {
            let cleaned = stripStepNumberPrefix(cleanText(step))
            if !cleaned.isEmpty {
                instructions.append(RecipeInstruction(stepNumber: instructions.count + 1, title: nil, text: cleaned, section: nil))
            }
        }

        guard !ingredients.isEmpty || !instructions.isEmpty else { return nil }

        return RecipeData(
            title: title,
            description: description,
            imageURL: nil,
            author: nil,
            sourceURL: sourceURL,
            yield: nil,
            prepTime: nil,
            cookTime: nil,
            totalTime: nil,
            category: nil,
            cuisine: nil,
            ingredients: ingredients,
            instructions: instructions,
            nutrition: nil
        )
    }

    // MARK: - Duration Helpers

    /// Converts ISO 8601 duration string (e.g. "PT15M", "PT1H30M", "P0DT1H") to friendly string ("15 mins", "1 hr 30 mins").
    static func parseDuration(_ val: Any?) -> String? {
        guard let val else { return nil }
        let raw = "\(val)".trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }

        if raw.hasPrefix("P") || raw.hasPrefix("PT") || raw.hasPrefix("-P") {
            if raw.contains("-") { return nil }
            // ISO 8601 Duration parser
            let pattern = #"^P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            let nsRange = NSRange(raw.startIndex..<raw.endIndex, in: raw)
            if let match = regex.firstMatch(in: raw, options: [], range: nsRange) {
                var days = 0, hours = 0, mins = 0
                if match.range(at: 1).location != NSNotFound, let r = Range(match.range(at: 1), in: raw) {
                    days = Int(raw[r]) ?? 0
                }
                if match.range(at: 2).location != NSNotFound, let r = Range(match.range(at: 2), in: raw) {
                    hours = Int(raw[r]) ?? 0
                }
                if match.range(at: 3).location != NSNotFound, let r = Range(match.range(at: 3), in: raw) {
                    mins = Int(raw[r]) ?? 0
                }

                // Guard negative/crazy values (like corrupted timestamps sometimes seen in Yoast bugs)
                if days < 0 || hours < 0 || mins < 0 || hours > 200 { return nil }

                var parts: [String] = []
                if days > 0 { parts.append("\(days) \(days == 1 ? "day" : "days")") }
                if hours > 0 { parts.append("\(hours) \(hours == 1 ? "hr" : "hrs")") }
                if mins > 0 { parts.append("\(mins) \(mins == 1 ? "min" : "mins")") }

                return parts.isEmpty ? nil : parts.joined(separator: " ")
            }
            return nil
        }

        let cleaned = cleanText(raw)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func parseStringOrArray(_ val: Any?) -> String? {
        guard let val else { return nil }
        if let str = val as? String {
            let cleaned = cleanText(str)
            return cleaned.isEmpty ? nil : cleaned
        } else if let arr = val as? [String] {
            let cleaned = arr.map { cleanText($0) }.filter { !$0.isEmpty }
            return cleaned.isEmpty ? nil : cleaned.joined(separator: ", ")
        }
        return nil
    }

    // MARK: - Cleaning & Normalization Helpers

    /// Strips HTML tags, unescapes entities, and collapses excess whitespace.
    static func cleanText(_ str: String) -> String {
        // Strip HTML tags
        var cleaned = str.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        // Unescape HTML entities
        cleaned = unescapeHTML(cleaned)
        // Normalize multiple spaces/newlines
        cleaned = cleaned.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Strips leading step prefixes like "1. ", "Step 1: ", "1) ".
    static func stripStepNumberPrefix(_ str: String) -> String {
        let pattern = #"^(?:Step\s*\d+[\s:.-]*|\d+\s*[.):-]\s*)"#
        return str.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Unescapes common and decimal/hex HTML entities.
    static func unescapeHTML(_ str: String) -> String {
        var result = str
        let table: [String: String] = [
            "&quot;": "\"",
            "&amp;": "&",
            "&apos;": "'",
            "&lt;": "<",
            "&gt;": ">",
            "&#39;": "'",
            "&#8217;": "'",
            "&#8216;": "'",
            "&#8220;": "\"",
            "&#8221;": "\"",
            "&nbsp;": " ",
            "&#160;": " ",
            "&frac12;": "½",
            "&#189;": "½",
            "&frac14;": "¼",
            "&#188;": "¼",
            "&frac34;": "¾",
            "&#190;": "¾",
            "&frac13;": "⅓",
            "&frac23;": "⅔",
            "&deg;": "°",
            "&#176;": "°",
            "&ndash;": "–",
            "&mdash;": "—",
            "&#8211;": "–",
            "&#8212;": "—",
            "&hellip;": "…"
        ]
        for (entity, replacement) in table {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }

        // Numeric decimal entities &#123;
        let decPattern = #"&#(\d+);"#
        if let decRegex = try? NSRegularExpression(pattern: decPattern) {
            let nsRange = NSRange(result.startIndex..<result.endIndex, in: result)
            let matches = decRegex.matches(in: result, range: nsRange).reversed()
            for m in matches {
                guard let numRange = Range(m.range(at: 1), in: result),
                      let fullRange = Range(m.range, in: result),
                      let code = UInt32(result[numRange]),
                      let scalar = UnicodeScalar(code) else { continue }
                result.replaceSubrange(fullRange, with: String(Character(scalar)))
            }
        }

        return result
    }

    private static func firstRegexMatch(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) else {
            return nil
        }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: nsRange),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private static func allRegexMatches(pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) else {
            return []
        }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: nsRange)
        return matches.compactMap { m in
            guard m.numberOfRanges > 1, let range = Range(m.range(at: 1), in: text) else { return nil }
            return String(text[range])
        }
    }
}
