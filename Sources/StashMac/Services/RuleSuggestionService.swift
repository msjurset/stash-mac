import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Errors surfaced by the rule-suggestion path. The Mac sheet branches
/// on these to render an actionable message rather than a generic
/// "something went wrong".
enum RuleSuggestionError: Error, LocalizedError {
    case unsupportedHardware
    case modelUnavailable(String)
    case noRecentActivity
    case modelFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedHardware:
            return "Rule suggestions require Apple Silicon with Apple Intelligence enabled in System Settings."
        case .modelUnavailable(let reason):
            return "On-device model unavailable: \(reason)"
        case .noRecentActivity:
            return "No recent manual tag activity to analyze. Tag a few items first."
        case .modelFailed(let detail):
            return "Suggestion failed: \(detail)"
        }
    }
}

/// Drives the on-device "Suggest a rule" feature. Reads the recent
/// tag-mutation log, buckets events by tag, asks the on-device
/// Foundation Models language model to characterize each bucket as a
/// RuleMatch, and returns suggestion cards ready to render.
///
/// The pre-bucketing keeps the model's job small: rather than asking
/// "find patterns in 100 events", we ask "given these 5 items that
/// all got tagged #video, what shared property explains the group?".
/// Less hallucination surface, more reliable output on the small
/// (~3B param) on-device model.
@MainActor
final class RuleSuggestionService {
    static let shared = RuleSuggestionService()

    /// True when the on-device model is reachable and ready. Mac UI
    /// uses this to grey out the Suggest button on Intel / non-AI hosts
    /// rather than firing the call and failing.
    var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        return false
        #else
        return false
        #endif
    }

    /// One-line reason why the model isn't available, suitable for
    /// tooltip / alert display. Returns nil when isAvailable is true.
    var unavailabilityReason: String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return nil
            case .unavailable(let reason):
                return String(describing: reason)
            }
        }
        return "Requires macOS 26.0 or later."
        #else
        return "Foundation Models framework not available in this build."
        #endif
    }

    /// Generate suggestions from the supplied tag events. Tags with
    /// fewer than `minSupporting` add-events are skipped (not enough
    /// signal for the model to characterize a pattern); tags whose
    /// names appear in `coveredTags` are skipped (an enabled rule
    /// already adds them, no point re-suggesting).
    func suggest(
        events: [TagEvent],
        minSupporting: Int = 3,
        coveredTags: Set<String> = [],
        skipFingerprints: Set<String> = [],
        maxSuggestions: Int = 8
    ) async throws -> [RuleSuggestion] {
        guard isAvailable else {
            throw RuleSuggestionError.unsupportedHardware
        }
        var buckets = Self.bucketByTag(events: events, minSupporting: minSupporting)
        if !coveredTags.isEmpty {
            buckets = buckets.filter { !coveredTags.contains($0.tag) }
        }
        if buckets.isEmpty {
            throw RuleSuggestionError.noRecentActivity
        }

        // Process buckets in parallel with bounded concurrency. Each
        // model call is 1-3s on the on-device 3B; serial = 10-25s for
        // a typical 8-bucket run. Whether this actually parallelizes
        // wall-clock depends on whether the FoundationModels framework
        // queues sessions internally on the Neural Engine — if it
        // does, this is a no-op (same wall-clock, no regression). If
        // it doesn't, we get a 3-4× speedup. Starting concurrency
        // conservative; bumping is cheap once the framework's behavior
        // is observed.
        let concurrency = 3

        // Tag results with their bucket index so we can preserve the
        // count-descending order even though the network of in-flight
        // tasks resolves out of order.
        struct Indexed {
            let index: Int
            let suggestion: RuleSuggestion?
        }

        var collected: [Indexed] = []
        try await withThrowingTaskGroup(of: Indexed.self) { group in
            var nextIndex = 0
            // Seed up to `concurrency` tasks.
            while nextIndex < min(concurrency, buckets.count) {
                let i = nextIndex
                let bucket = buckets[i]
                group.addTask { [weak self] in
                    let suggestion = try? await self?.characterize(bucket: bucket)
                    return Indexed(index: i, suggestion: suggestion ?? nil)
                }
                nextIndex += 1
            }

            // Drain and re-seed. Stop once we have enough qualifying
            // suggestions — a runaway model on a long bucket list
            // shouldn't keep firing once the user has results to look
            // at. Ordering inside `collected` doesn't matter here; we
            // sort by index after the group settles.
            while let result = try await group.next() {
                let qualifying = result.suggestion.map { !skipFingerprints.contains($0.fingerprint) } ?? false
                if qualifying { collected.append(result) }

                if collected.count >= maxSuggestions {
                    group.cancelAll()
                    break
                }

                if nextIndex < buckets.count {
                    let i = nextIndex
                    let bucket = buckets[i]
                    group.addTask { [weak self] in
                        let suggestion = try? await self?.characterize(bucket: bucket)
                        return Indexed(index: i, suggestion: suggestion ?? nil)
                    }
                    nextIndex += 1
                }
            }
        }

        return collected
            .sorted { $0.index < $1.index }
            .compactMap { $0.suggestion }
            .prefix(maxSuggestions)
            .map { $0 }
    }

    /// Synthesize TagEvent records from the live item↔tag snapshot in
    /// the store. The audit log only captures *future* tag mutations
    /// (everything tagged after we shipped the logger); for an
    /// established library this misses years of user signal. A
    /// snapshot pass surfaces all of it as input to the suggester.
    ///
    /// Snapshot events are marked `source: "snapshot"` so the audit
    /// log stays distinguishable. `timestamp` is set to the item's
    /// own creation time (the closest stand-in we have for "when this
    /// tag was applied" — it's wrong for tags added later, but close
    /// enough; the model doesn't read timestamps).
    static func eventsFromItemSnapshot(items: [StashItem]) -> [TagEvent] {
        var out: [TagEvent] = []
        for item in items {
            guard let tags = item.tags, !tags.isEmpty else { continue }
            let domain = item.url.flatMap(extractDomain)
            for tag in tags {
                out.append(TagEvent(
                    timestamp: item.createdAt,
                    action: "add",
                    tag: tag.name,
                    itemId: item.id,
                    itemType: item.type.rawValue,
                    itemUrl: item.url,
                    itemDomain: domain,
                    source: "snapshot"
                ))
            }
        }
        return out
    }

    /// Merge two event lists, deduping per (itemId, tag, action). The
    /// real audit log wins when an item↔tag pair appears in both —
    /// it has a true timestamp; the snapshot timestamp is a stand-in.
    static func mergeEvents(audit: [TagEvent], snapshot: [TagEvent]) -> [TagEvent] {
        var seen = Set<String>()
        var out: [TagEvent] = []
        let key: (TagEvent) -> String = { "\($0.itemId)|\($0.tag)|\($0.action)" }
        for ev in audit {
            if seen.insert(key(ev)).inserted {
                out.append(ev)
            }
        }
        for ev in snapshot {
            if seen.insert(key(ev)).inserted {
                out.append(ev)
            }
        }
        return out
    }

    /// Tags any enabled rule already adds. Used to filter buckets
    /// whose suggestion would just duplicate an existing rule.
    static func tagsCoveredByEnabledRules(_ rules: [Rule]) -> Set<String> {
        var covered = Set<String>()
        for rule in rules where rule.isEnabled {
            for action in rule.actions ?? [] {
                for tag in action.addTags ?? [] {
                    covered.insert(tag)
                }
            }
        }
        return covered
    }

    private static func extractDomain(_ rawURL: String) -> String? {
        guard let url = URL(string: rawURL), let host = url.host else { return nil }
        let lower = host.lowercased()
        if lower.hasPrefix("www.") { return String(lower.dropFirst(4)) }
        return lower
    }

    // MARK: - Pre-bucketing

    /// Tag → list of `add` events for that tag, with at least
    /// `minSupporting` events. We deliberately ignore `remove`
    /// events — they're typically corrections, not signal of "this
    /// is what I tag X with".
    static func bucketByTag(events: [TagEvent], minSupporting: Int) -> [TagBucket] {
        var byTag: [String: [TagEvent]] = [:]
        for ev in events where ev.action == "add" {
            byTag[ev.tag, default: []].append(ev)
        }
        var out: [TagBucket] = []
        for (tag, evs) in byTag {
            // Dedupe by item id — the same item tagged + retagged
            // shouldn't inflate the supporting count.
            var seen = Set<String>()
            var unique: [TagEvent] = []
            for ev in evs {
                if seen.insert(ev.itemId).inserted {
                    unique.append(ev)
                }
            }
            if unique.count >= minSupporting {
                out.append(TagBucket(tag: tag, events: unique))
            }
        }
        // Largest buckets first — more supporting events = more
        // confident pattern. Cap the per-bucket sample size to keep
        // each prompt small.
        return out.sorted { $0.events.count > $1.events.count }
    }

    struct TagBucket {
        let tag: String
        let events: [TagEvent]
    }

    // MARK: - Model interaction

    private func characterize(bucket: TagBucket) async throws -> RuleSuggestion? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return try await characterizeWithFoundationModels(bucket: bucket)
        }
        return nil
        #else
        return nil
        #endif
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private func characterizeWithFoundationModels(bucket: TagBucket) async throws -> RuleSuggestion? {
        let session = LanguageModelSession(instructions: Self.systemInstructions)
        let prompt = Self.buildPrompt(bucket: bucket)
        do {
            let response = try await session.respond(
                to: prompt,
                generating: RuleMatchProposal.self
            )
            let proposal = response.content
            guard proposal.proposeRule else { return nil }
            return Self.makeSuggestion(from: proposal, bucket: bucket)
        } catch {
            throw RuleSuggestionError.modelFailed(error.localizedDescription)
        }
    }
    #endif

    static let systemInstructions = """
You analyze a user's tagging behavior on a personal bookmark archive \
and determine what single property best explains why a group of items \
share the same tag.

Your job is narrow: given a list of items the user manually tagged \
with the same tag, identify which item property (domain, item type, \
or URL regex) characterizes the group. Pick the simplest explanation \
that matches all items.

Rules:
- Prefer `domain` when all items share a host (e.g. all from \
  youtube.com). Use the bare hostname without scheme or path.
- Use `type` when all items share a content type (link, file, \
  snippet, image, email) AND no tighter pattern fits.
- Use `urlRegex` ONLY when there is no shared domain across the \
  items but a URL substring pattern does explain the group \
  (e.g. all paths contain '/blog/'). When domain is set, leave \
  urlRegex empty — domain alone already constrains the match.
- Set `proposeRule = false` when the items don't share any clear \
  property. Don't invent patterns just to produce output.
"""

    static func buildPrompt(bucket: TagBucket) -> String {
        var lines: [String] = []
        lines.append("Tag: #\(bucket.tag)")
        lines.append("Items the user tagged with this:")
        for (i, ev) in bucket.events.prefix(15).enumerated() {
            var parts: [String] = ["#\(i + 1)"]
            if let t = ev.itemType { parts.append("type=\(t)") }
            if let d = ev.itemDomain, !d.isEmpty { parts.append("domain=\(d)") }
            if let u = ev.itemUrl, !u.isEmpty { parts.append("url=\(u)") }
            lines.append("- " + parts.joined(separator: " "))
        }
        return lines.joined(separator: "\n")
    }

    @available(macOS 26.0, *)
    static func makeSuggestion(from proposal: RuleMatchProposal, bucket: TagBucket) -> RuleSuggestion {
        let domain = nilIfEmpty(proposal.domain)
        let type = nilIfEmpty(proposal.type)
        let urlRegex = sanitizedURLRegex(proposal.urlRegex, domain: domain)
        let match = RuleMatch(
            type: type,
            domain: domain,
            urlRegex: urlRegex
        )
        let pattern = patternStatement(bucket: bucket, match: match)
        let name = makeRuleName(bucket: bucket, match: match)
        return RuleSuggestion(
            id: UUID(),
            pattern: pattern,
            name: name,
            match: match,
            addTags: [bucket.tag],
            supportingItemIDs: bucket.events.map { $0.itemId }
        )
    }

    private static func nilIfEmpty(_ s: String) -> String? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Drop urlRegex when it would be redundant or wrong. The on-device
    /// model often pads a domain match with a urlRegex that's either
    /// a) just the domain in regex form (redundant), b) a malformed
    /// URL fragment that doesn't actually match the items, or c)
    /// syntactically valid regex that won't compile. Domain-set rules
    /// almost never need urlRegex — see system instructions.
    private static func sanitizedURLRegex(_ raw: String, domain: String?) -> String? {
        guard let candidate = nilIfEmpty(raw) else { return nil }
        // Domain set → urlRegex is noise. Match2's "https://gon/.+" was
        // exactly this case (gon vs gon.com mismatch on top of being
        // already covered by the domain filter).
        if domain != nil { return nil }
        // Compile-check; an unparseable regex would just throw at rule
        // engine time, so reject upfront.
        if (try? NSRegularExpression(pattern: candidate)) == nil { return nil }
        return candidate
    }

    /// User-visible "why this group" sentence, built from the bucket
    /// + the (already-sanitized) match. Replaces the LLM `rationale`
    /// field, which the small on-device model can't be trusted to
    /// keep consistent with its own structural output.
    private static func patternStatement(bucket: TagBucket, match: RuleMatch) -> String {
        let n = bucket.events.count
        let countWord = "\(n) item\(n == 1 ? "" : "s")"
        if let domain = match.domain {
            return "\(countWord) from \(domain) tagged with #\(bucket.tag)."
        }
        if let regex = match.urlRegex {
            return "\(countWord) whose URLs match `\(regex)` tagged with #\(bucket.tag)."
        }
        if let type = match.type {
            return "\(countWord) of type \(type) tagged with #\(bucket.tag)."
        }
        return "\(countWord) share the tag #\(bucket.tag)."
    }

    /// Build a stable rule name. Prefer "<domain>-<tag>" when there's
    /// a domain, "<type>-<tag>" otherwise — keeps the rules list
    /// scannable and avoids name collisions on common tags.
    private static func makeRuleName(bucket: TagBucket, match: RuleMatch) -> String {
        if let domain = match.domain {
            let key = domain
                .replacingOccurrences(of: ".", with: "-")
                .replacingOccurrences(of: " ", with: "-")
            return "\(key)-\(bucket.tag)"
        }
        if let type = match.type {
            return "\(type)-\(bucket.tag)"
        }
        return "auto-\(bucket.tag)"
    }
}

#if canImport(FoundationModels)
/// Typed output the model produces for each tag bucket. The struct
/// shape is the prompt's grammar — fewer free-form fields = less
/// drift on the small on-device model. We deliberately do NOT ask
/// the model for a free-form rationale: the 3B-param on-device model
/// reliably hallucinates prose that contradicts its own structural
/// fields ("All five items are YouTube video pages" for a #health
/// rule on mychart.emoryhealthcare.org). The user-visible pattern
/// statement is generated client-side from the bucket data instead.
@available(macOS 26.0, *)
@Generable
struct RuleMatchProposal {
    @Guide(description: "Hostname like 'youtube.com' if all items share a host. Empty string if no domain pattern.")
    var domain: String

    @Guide(description: "Item type — one of 'link', 'file', 'snippet', 'image', 'email'. Empty string if items have mixed types.")
    var type: String

    @Guide(description: "Regex matching shared URL substrings, when there is no shared domain but a URL pattern explains the group. Empty string when domain is set or when no URL pattern applies.")
    var urlRegex: String

    @Guide(description: "True if a rule should be proposed. False when the items don't share a clear property — don't invent patterns.")
    var proposeRule: Bool
}
#endif
