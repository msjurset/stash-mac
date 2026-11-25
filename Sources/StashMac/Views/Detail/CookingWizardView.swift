import SwiftUI
import AppKit
import AVFoundation
import IOKit.pwr_mgt

@Observable
@MainActor
final class CookingSpeechController: NSObject, AVSpeechSynthesizerDelegate {
    var isSpeaking: Bool = false
    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(step: RecipeInstruction, voiceID: String) {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        var parts: [String] = ["Step \(step.stepNumber)."]
        if let title = step.displayTitle, !title.isEmpty {
            parts.append(title.hasSuffix(".") || title.hasSuffix("!") || title.hasSuffix("?") ? title : "\(title).")
        }
        parts.append(step.text)
        let utterance = AVSpeechUtterance(string: parts.joined(separator: " "))
        if voiceID != "default", let voice = AVSpeechSynthesisVoice(identifier: voiceID) {
            utterance.voice = voice
        } else if let voice = AVSpeechSynthesisVoice.speechVoices().first(where: { $0.quality == .premium && $0.language == "en-US" }) {
            utterance.voice = voice
        } else if let voice = AVSpeechSynthesisVoice.speechVoices().first(where: { $0.quality == .enhanced && $0.language == "en-US" }) {
            utterance.voice = voice
        } else if let voice = AVSpeechSynthesisVoice(language: "en-US") {
            utterance.voice = voice
        }
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        isSpeaking = false
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
        }
    }
}

/// Step-by-step interactive Cooking Assistant modal sheet.
/// Highlights the active recipe instruction in high-contrast typography, keeps the
/// ingredients checklist pinned on the left for quick reference, and lets the user
/// advance through steps hands-free using the Spacebar (or arrow keys).
struct CookingWizardView: View {
    @Environment(\.dismiss) private var dismiss

    let recipe: RecipeData
    var onFinishCooking: ((Int?, String?) -> Void)? = nil

    @AppStorage("cookingVoiceID") private var voiceID: String = "default"
    @AppStorage("cookingAutoSpeak") private var autoSpeak: Bool = false

    @State private var currentStepIndex: Int = 0
    @State private var completedSteps: Set<Int> = []
    @State private var checkedIngredients: Set<String> = []
    @State private var logAsCooked: Bool = true
    @State private var cookRating: Int = 0
    @State private var cookNote: String = ""
    @State private var hasLoggedSession: Bool = false
    @State private var keyMonitor: Any?
    @State private var sleepAssertionID: IOPMAssertionID = 0
    @State private var processActivityToken: NSObjectProtocol?
    @State private var speechController = CookingSpeechController()

    private var steps: [RecipeInstruction] {
        recipe.instructions
    }

    private var totalSteps: Int {
        steps.count
    }

    private var isFinished: Bool {
        totalSteps > 0 && currentStepIndex >= totalSteps
    }

    private var progressFraction: Double {
        guard totalSteps > 0 else { return 1.0 }
        if isFinished { return 1.0 }
        return Double(currentStepIndex + 1) / Double(totalSteps)
    }

    private var wizardSize: CGSize {
        if let screen = NSScreen.main?.visibleFrame {
            let w = min(max(1180, screen.width * 0.84), 1480)
            let h = min(max(780, screen.height * 0.85), 1000)
            return CGSize(width: w, height: h)
        }
        return CGSize(width: 1220, height: 820)
    }

    var body: some View {
        let size = wizardSize
        VStack(spacing: 0) {
            wizardHeader

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.08))
                    Rectangle()
                        .fill(Color.orange)
                        .frame(width: geo.size.width * progressFraction)
                        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: progressFraction)
                }
            }
            .frame(height: 6)

            HStack(spacing: 0) {
                if !recipe.ingredients.isEmpty {
                    ingredientsSidebar
                        .frame(width: 350)
                    Divider()
                }

                stepsColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()

            wizardFooter
        }
        .frame(minWidth: 1080, idealWidth: size.width, maxWidth: .infinity, minHeight: 740, idealHeight: size.height, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            acquireDisplaySleepAssertion()
            installKeyboardMonitor()
            if autoSpeak {
                speakCurrentStep()
            }
        }
        .onChange(of: currentStepIndex) { _, _ in
            if autoSpeak && !isFinished {
                speakCurrentStep()
            } else {
                speechController.stop()
            }
        }
        .onDisappear {
            speechController.stop()
            removeKeyboardMonitor()
            releaseDisplaySleepAssertion()
        }
    }

    // MARK: - Header

    private var wizardHeader: some View {
        HStack(spacing: 14) {
            Image(systemName: "flame.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 3) {
                Text(recipe.title)
                    .font(.system(size: 22, weight: .bold))
                    .lineLimit(1)
                HStack(spacing: 10) {
                    if isFinished {
                        Text("All \(totalSteps) steps complete!")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.green)
                    } else if totalSteps > 0 {
                        Text("Step \(currentStepIndex + 1) of \(totalSteps)")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.orange)
                    }
                    if let totalTime = recipe.totalTime, !totalTime.isEmpty {
                        Text("• \(totalTime)")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                    if let yld = recipe.yield, !yld.isEmpty {
                        Text("• \(yld)")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            if !isFinished && totalSteps > 0 {
                Button {
                    toggleSpeakCurrentStep()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: autoSpeak ? "speaker.wave.2.fill" : "speaker.slash")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Speak")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(
                        Capsule()
                            .fill(autoSpeak ? Color.orange.opacity(0.18) : Color.primary.opacity(0.06))
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(autoSpeak ? Color.orange.opacity(0.6) : Color.clear, lineWidth: 1)
                    )
                    .foregroundStyle(autoSpeak ? Color.orange : Color.secondary)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help("Read steps aloud (S)")
            }

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("Close Cooking Assistant (Esc)")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func speakCurrentStep() {
        guard !isFinished, currentStepIndex >= 0, currentStepIndex < steps.count else { return }
        speechController.speak(step: steps[currentStepIndex], voiceID: voiceID)
    }

    private func toggleSpeakCurrentStep() {
        autoSpeak.toggle()
        if autoSpeak {
            speakCurrentStep()
        } else {
            speechController.stop()
        }
    }

    // MARK: - Ingredients Sidebar

    private var activeMatchedIngredientIndices: Set<Int> {
        if isFinished { return [] }
        return Self.matchedIngredientIndices(
            stepIndex: currentStepIndex,
            steps: steps.map(\.text),
            ingredients: recipe.ingredients.map(\.text)
        )
    }

    private var ingredientsSidebar: some View {
        let activeMatchedIndices = activeMatchedIngredientIndices
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Label("Ingredients", systemImage: "basket.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !activeMatchedIndices.isEmpty {
                    Text("Need Now: \(activeMatchedIndices.count)")
                        .font(.system(size: 12, weight: .bold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(Color.orange.opacity(0.16), in: Capsule())
                        .overlay(
                            Capsule()
                                .strokeBorder(Color.orange.opacity(0.45), lineWidth: 1)
                        )
                        .foregroundStyle(.orange)
                }
                if !checkedIngredients.isEmpty {
                    Button("Reset") {
                        checkedIngredients.removeAll()
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(.orange)
                    .focusable(false)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            Divider()

            ScrollViewReader { ingProxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(recipe.ingredients.enumerated()), id: \.offset) { idx, ing in
                            let key = "\(idx)-\(ing.text)"
                            let isChecked = checkedIngredients.contains(key)
                            let isUsedInCurrentStep = activeMatchedIndices.contains(idx)

                            VStack(alignment: .leading, spacing: 5) {
                                if let sec = ing.section, !sec.isEmpty,
                                   (idx == 0 || recipe.ingredients[idx - 1].section != sec) {
                                    Text(sec.uppercased())
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(.orange)
                                        .padding(.top, idx == 0 ? 0 : 8)
                                }

                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 18))
                                        .foregroundStyle(isChecked ? Color.green : (isUsedInCurrentStep ? Color.orange : Color.secondary.opacity(0.6)))
                                        .padding(.top, 2)

                                    Text(ing.text)
                                        .font(.system(size: 16, weight: isUsedInCurrentStep && !isChecked ? .semibold : .regular))
                                        .strikethrough(isChecked, color: .secondary)
                                        .foregroundStyle(isChecked ? .secondary : .primary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 0)

                                    if isUsedInCurrentStep {
                                        Text("Step \(currentStepIndex + 1)")
                                            .font(.system(size: 11, weight: .bold))
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 3)
                                            .background(Color.orange, in: Capsule())
                                            .foregroundStyle(.white)
                                    }
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(isUsedInCurrentStep && !isChecked ? Color.orange.opacity(0.12) : Color.clear)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .strokeBorder(isUsedInCurrentStep && !isChecked ? Color.orange.opacity(0.45) : Color.clear, lineWidth: 1)
                                )
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if isChecked {
                                        checkedIngredients.remove(key)
                                    } else {
                                        checkedIngredients.insert(key)
                                    }
                                }
                            }
                            .id("ing-\(idx)")
                        }
                    }
                    .padding(14)
                }
                .onChange(of: currentStepIndex) { _, _ in
                    if let firstIdx = activeMatchedIngredientIndices.min() {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            ingProxy.scrollTo("ing-\(firstIdx)", anchor: .center)
                        }
                    }
                }
            }
        }
        .background(Color.primary.opacity(0.02))
    }

    /// Computes the set of ingredient indices highlighted for `stepIndex`, combining lexical/compound
    /// disambiguation (`stepMentionsIngredient`) with recipe-wide sequential consumption and gap pruning.
    static func matchedIngredientIndices(
        stepIndex: Int,
        steps: [String],
        ingredients: [String]
    ) -> Set<Int> {
        guard stepIndex >= 0, stepIndex < steps.count, !ingredients.isEmpty else { return [] }

        let garnishStepKeywords: Set<String> = [
            "garnish", "garnishes", "serve", "serving", "top", "topping",
            "toppings", "sprinkle", "finish", "divide", "plate", "platter"
        ]
        let sharedHeads = [
            "oil", "onion", "onions", "vinegar", "sugar", "flour", "garlic",
            "butter", "pepper", "peppers", "salt", "broth", "stock", "sauce", "milk", "cream", "cheese"
        ]
        let collectiveSpiceTriggers: Set<String> = [
            "spice", "spices", "seasoning", "seasonings", "herb", "herbs"
        ]
        let spiceAndHerbLexicon: Set<String> = [
            "cumin", "paprika", "cinnamon", "coriander", "turmeric", "cayenne", "oregano", "thyme",
            "rosemary", "basil", "nutmeg", "clove", "cloves", "allspice", "cardamom", "ginger",
            "curry", "masala", "garam", "fennel", "dill", "bay", "parsley", "cilantro", "sage",
            "marjoram", "tarragon", "zaatar", "sumac", "saffron", "fenugreek", "caraway", "anise",
            "mustard", "cajun", "creole", "tajin", "chili", "chile", "powder", "flakes",
            "peppercorn", "peppercorns", "seasoning", "spice", "spices", "herb", "herbs"
        ]

        let isGarnishIng: [Bool] = ingredients.map { hasGarnishOrServingRole(normalizeText($0)) }
        let isDividedIng: [Bool] = ingredients.map { isDividedIngredientLine(normalizeText($0)) }

        var matchedInGarnishStep = Set<Int>()
        var everExplicitlyMatched = Set<Int>()
        for (sIdx, sText) in steps.enumerated() {
            let finalFlag = (sIdx == steps.count - 1)
            let sTokens = Set(
                normalizeText(sText)
                    .components(separatedBy: CharacterSet.alphanumerics.inverted)
                    .filter { !$0.isEmpty }
            )
            let isGarnishStep = finalFlag || !sTokens.isDisjoint(with: garnishStepKeywords)
            for (iIdx, ing) in ingredients.enumerated() {
                if stepMentionsIngredient(stepText: sText, ingredientLine: ing, isFinalStep: finalFlag) {
                    everExplicitlyMatched.insert(iIdx)
                    if isGarnishIng[iIdx] && isGarnishStep {
                        matchedInGarnishStep.insert(iIdx)
                    }
                }
            }
        }

        var consumedByEarlierSteps = Set<Int>()

        for sIdx in 0...stepIndex {
            let stepText = steps[sIdx]
            let isFinalStep = (sIdx == steps.count - 1)
            let normalizedStep = normalizeText(stepText)
            let stepWords = normalizedStep
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
            let stepTokens = Set(stepWords)
            let isGarnishStep = isFinalStep || !stepTokens.isDisjoint(with: garnishStepKeywords)
            let stepAllowsReuse = stepHasSplitOrRemainderPhrase(normalizedStep)

            // 1. Per-ingredient lexical match for step `sIdx`
            var matched = Set<Int>()
            for (idx, ing) in ingredients.enumerated() {
                if isGarnishIng[idx] && !isGarnishStep && matchedInGarnishStep.contains(idx) {
                    continue
                }
                if stepMentionsIngredient(stepText: stepText, ingredientLine: ing, isFinalStep: isFinalStep) {
                    matched.insert(idx)
                }
            }

            // 2. Prior-step consumption filter:
            //    Once a non-divided ingredient has been introduced and used in an earlier step,
            //    anaphoric back-references in later steps ("Brown the beef", "return the beef to the pot",
            //    "until the beef is very tender", "Remove the bay leaf") should not re-highlight it.
            for idx in matched {
                if consumedByEarlierSteps.contains(idx) && !isDividedIng[idx] && !stepAllowsReuse {
                    matched.remove(idx)
                }
            }

            if matched.count > 1 {
                // 3. Shared generic head noun disambiguation (e.g. "oil", "onion", "salt", "pepper")
                for head in sharedHeads where tokenSetMatches(stepTokens, word: head) {
                    let matchingThisHead = matched.filter { idx in
                        let tokens = significantIngredientTokens(ingredients[idx])
                        return tokens.contains { tokenSetMatches([head], word: $0) }
                    }
                    guard matchingThisHead.count > 1 else { continue }

                    let explicitlyQualified = matchingThisHead.filter { idx in
                        let otherTokens = significantIngredientTokens(ingredients[idx]).filter { !tokenSetMatches([head], word: $0) }
                        return !otherTokens.isEmpty && otherTokens.contains { tokenSetMatches(stepTokens, word: $0) }
                    }
                    if !explicitlyQualified.isEmpty {
                        for idx in matchingThisHead where !explicitlyQualified.contains(idx) {
                            matched.remove(idx)
                        }
                        continue
                    }

                    let unqualified = matchingThisHead.filter { idx in
                        let otherTokens = significantIngredientTokens(ingredients[idx]).filter { !tokenSetMatches([head], word: $0) }
                        return otherTokens.isEmpty
                    }
                    if !unqualified.isEmpty {
                        for idx in matchingThisHead where !unqualified.contains(idx) {
                            matched.remove(idx)
                        }
                        continue
                    }

                    let unusedInEarlierSteps = matchingThisHead.filter { !consumedByEarlierSteps.contains($0) }
                    if !unusedInEarlierSteps.isEmpty && unusedInEarlierSteps.count < matchingThisHead.count {
                        for idx in matchingThisHead where !unusedInEarlierSteps.contains(idx) {
                            matched.remove(idx)
                        }
                    }
                }

                // 4. Contiguous-Cluster Gap Outlier Pruning
                let sorted = matched.sorted()
                if sorted.count >= 3 {
                    var clusters: [[Int]] = []
                    for idx in sorted {
                        if let lastCluster = clusters.last, let prev = lastCluster.last, (idx - prev) <= 2 {
                            clusters[clusters.count - 1].append(idx)
                        } else {
                            clusters.append([idx])
                        }
                    }

                    if let primaryCluster = clusters.max(by: { $0.count < $1.count }), primaryCluster.count >= 2 {
                        let primaryMin = primaryCluster.first!
                        let primaryMax = primaryCluster.last!
                        let primaryTokens = Set(primaryCluster.flatMap { significantIngredientTokens(ingredients[$0]) })

                        for cluster in clusters where cluster.count == 1 {
                            let outlierIdx = cluster[0]
                            let gap = outlierIdx < primaryMin ? (primaryMin - outlierIdx - 1) : (outlierIdx - primaryMax - 1)
                            guard gap >= 3 else { continue }

                            let outlierTokens = Set(significantIngredientTokens(ingredients[outlierIdx]))
                            let sharesWordWithPrimary = !outlierTokens.isDisjoint(with: primaryTokens)
                            let usedEarlier = consumedByEarlierSteps.contains(outlierIdx)
                            let usedLater: Bool = {
                                guard sIdx + 1 < steps.count else { return false }
                                for nextIdx in (sIdx + 1)..<steps.count {
                                    if stepMentionsIngredient(
                                        stepText: steps[nextIdx],
                                        ingredientLine: ingredients[outlierIdx],
                                        isFinalStep: nextIdx == steps.count - 1
                                    ) {
                                        return true
                                    }
                                }
                                return false
                            }()

                            if sharesWordWithPrimary || usedEarlier || usedLater {
                                matched.remove(outlierIdx)
                            }
                        }
                    }
                }
            }

            // 5. Unclaimed Interior Gap & Collective Spice/Seasoning Bridging
            let postPruneSorted = matched.sorted()
            if postPruneSorted.count >= 2 {
                for pairIdx in 0..<(postPruneSorted.count - 1) {
                    let low = postPruneSorted[pairIdx]
                    let high = postPruneSorted[pairIdx + 1]
                    let gapCount = high - low - 1
                    if gapCount >= 1 && gapCount <= 6 {
                        let gapRange = (low + 1)..<high
                        if gapRange.allSatisfy({ !everExplicitlyMatched.contains($0) && !consumedByEarlierSteps.contains($0) }) {
                            for k in gapRange {
                                matched.insert(k)
                            }
                        }
                    }
                }
            }

            if !stepTokens.isDisjoint(with: collectiveSpiceTriggers) {
                for (iIdx, ing) in ingredients.enumerated() where !everExplicitlyMatched.contains(iIdx) && !consumedByEarlierSteps.contains(iIdx) {
                    let ingTokens = Set(significantIngredientTokens(ing))
                    if !ingTokens.isDisjoint(with: spiceAndHerbLexicon) {
                        matched.insert(iIdx)
                    }
                }
            }

            if sIdx == stepIndex {
                return matched
            }
            consumedByEarlierSteps.formUnion(matched)
        }

        return []
    }

    private static func hasGarnishOrServingRole(_ normalizedIng: String) -> Bool {
        normalizedIng.contains("garnish")
            || normalizedIng.contains("to serve")
            || normalizedIng.contains("for serving")
            || normalizedIng.contains("for topping")
    }

    private static func isDividedIngredientLine(_ normalizedIng: String) -> Bool {
        normalizedIng.contains("divided")
            || normalizedIng.contains("plus more")
            || normalizedIng.contains("reserved")
            || normalizedIng.contains("or more")
    }

    private static func stepHasSplitOrRemainderPhrase(_ normalizedStep: String) -> Bool {
        normalizedStep.contains("remaining")
            || normalizedStep.contains("rest of")
            || normalizedStep.contains("other half")
            || normalizedStep.contains("second half")
            || normalizedStep.contains("reserved")
    }

    /// Highlights ingredients in the sidebar whose core culinary noun/phrase appears in the active step text,
    /// while disambiguating compound ingredients (e.g. "Beef Broth" != "the beef"; "peanut sauce" / "peanut butter" != "peanuts";
    /// "salt and pepper" -> black pepper, not jalapeño/bell pepper; "minced garlic" -> fresh garlic, not garlic powder).
    static func stepMentionsIngredient(stepText: String, ingredientLine: String, isFinalStep: Bool = false) -> Bool {
        let normalizedStep = normalizeText(stepText)
        let rawNormalizedIng = normalizeText(ingredientLine)
        let normalizedIng = stripEditorialNotes(rawNormalizedIng)

        let stepWords = normalizedStep
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let stepTokens = Set(stepWords)
        guard !stepTokens.isEmpty else { return false }

        let ingWords = significantIngredientTokens(normalizedIng)
        let ingTokenSet = Set(ingWords)
        guard !ingWords.isEmpty else { return false }

        // 0. Garnish / Serving Role Guard for shared generic nouns when called directly:
        //    If the ingredient is marked "to garnish" / "for serving" and has a qualifier on a generic noun
        //    (e.g. "green onions to garnish") or is checked against a non-final step that lacks garnish keywords
        //    and lacks the ingredient's specific qualifier, suppress false matches on bare generic nouns.
        let isGarnishIngredient = hasGarnishOrServingRole(rawNormalizedIng)
        let garnishStepKeywords: Set<String> = [
            "garnish", "garnishes", "serve", "serving", "top", "topping",
            "toppings", "sprinkle", "finish", "divide", "plate", "platter"
        ]

        // 1. Transformative / derivative product head nouns:
        //    When an ingredient is a broth, stock, bouillon, paste, powder, extract, essence, starch, flour,
        //    vinegar, oil, juice, or zest (e.g. "2 Cups Beef Broth", "1/4 Cup Tomato Paste", "1 tsp garlic powder",
        //    "2 tbsp olive oil", "2 tbsp rice vinegar"), the step MUST mention the derivative head noun itself
        //    (or a valid synonym like "broth"/"stock", or collective "spices"/"seasoning" for "powder").
        //    A modifier word like "beef" in "Beef Broth" or "tomato" in "Tomato Paste" must NEVER trigger a match
        //    when the step only refers to "the beef" or "the tomatoes"!
        let transformativeNouns: Set<String> = [
            "powder", "paste", "extract", "essence",
            "broth", "stock", "bouillon",
            "starch", "flour", "meal",
            "vinegar", "oil", "juice", "zest"
        ]
        let brothSynonyms: Set<String> = ["broth", "stock", "bouillon"]
        let activeTransformativeHeads = ingTokenSet.intersection(transformativeNouns)

        for trans in activeTransformativeHeads {
            if brothSynonyms.contains(trans) {
                let hasBrothWord = brothSynonyms.contains { tokenSetMatches(stepTokens, word: $0) }
                if !hasBrothWord {
                    return false
                }
            } else if trans == "powder" {
                if !tokenSetMatches(stepTokens, word: trans)
                    && !stepTokens.contains("spice")
                    && !stepTokens.contains("spices")
                    && !stepTokens.contains("seasoning")
                    && !stepTokens.contains("seasonings") {
                    return false
                }
            } else {
                if !tokenSetMatches(stepTokens, word: trans) {
                    return false
                }
            }
        }

        // 2. Produce/chili peppers vs. seasoning pepper ("salt and pepper" / "black pepper"):
        let chiliOrProducePepperSpecifiers: Set<String> = [
            "jalapeno", "jalapenos", "bell", "serrano", "poblano", "habanero", "anaheim",
            "cayenne", "chili", "chile", "chipotle", "banana", "cubanelle", "padron",
            "shishito", "sweet", "green", "red", "yellow", "orange", "mini", "roasted"
        ]
        let hasPepperWord = ingTokenSet.contains("pepper") || ingTokenSet.contains("peppers")
        let ingPepperSpecifiers = ingTokenSet.intersection(chiliOrProducePepperSpecifiers)

        // 3. Shared generic nouns ("oil", "vinegar", "onion", "sugar", "flour", "milk", "wine", "sauce", "broth", "stock")
        //    where a qualifier in the ingredient must not conflict with a different qualifier in the step.
        let genericHeadNouns: Set<String> = [
            "pepper", "peppers", "oil", "vinegar", "onion", "onions", "sugar",
            "wine", "sauce", "milk", "cream", "butter", "salt", "broth", "stock", "paste", "juice", "zest", "flour", "starch"
        ]
        let qualifiers: Set<String> = [
            "olive", "sesame", "vegetable", "canola", "coconut", "peanut", "avocado", "sunflower",
            "white", "red", "balsamic", "apple", "cider", "rice", "distilled", "malt", "sherry",
            "yellow", "green", "sweet", "spring", "brown", "powdered", "confectioners", "granulated", "caster",
            "soy", "fish", "worcestershire", "hot", "bbq", "barbecue", "tomato", "marinara", "oyster", "hoisin",
            "almond", "oat", "evaporated", "condensed", "heavy", "sour", "kosher", "sea", "celery", "garlic",
            "beef", "chicken", "pork", "turkey", "mushroom", "bone", "curry", "chili", "chile",
            "lemon", "lime", "orange", "corn", "potato", "tapioca", "wheat"
        ]

        var candidateWords = ingWords

        // For transformative head nouns (e.g. "Beef Broth", "Tomato Paste", "Olive Oil"), remove modifier tokens
        // unless they appear adjacent to the transformative head noun in the step, so "beef" in "Brown the beef"
        // cannot match "Beef Broth" even if "broth" appeared elsewhere in the step.
        if !activeTransformativeHeads.isEmpty {
            let allowedHeadMatches = activeTransformativeHeads.union(
                !activeTransformativeHeads.isDisjoint(with: brothSynonyms) ? brothSynonyms : []
            )
            candidateWords = candidateWords.filter { word in
                if activeTransformativeHeads.contains(word) {
                    return true
                }
                return stepContainsModifierBeforeHead(stepWords: stepWords, modifier: word, heads: allowedHeadMatches)
            }
        }

        if hasPepperWord && !ingPepperSpecifiers.isEmpty {
            let stepIsSeasoningPepper = normalizedStep.contains("salt and pepper")
                || normalizedStep.contains("salt & pepper")
                || normalizedStep.contains("black pepper")
                || normalizedStep.contains("white pepper")
                || normalizedStep.contains("ground pepper")
                || normalizedStep.contains("cracked pepper")
                || normalizedStep.contains("pepper to taste")

            if stepIsSeasoningPepper || !stepTokens.contains("peppers") {
                candidateWords.removeAll { $0 == "pepper" || $0 == "peppers" }
            }
        }

        let ingQualifiers = ingTokenSet.intersection(qualifiers)
        if !ingQualifiers.isEmpty {
            for head in genericHeadNouns where ingTokenSet.contains(head) {
                let stepHasIngQualifier = ingQualifiers.contains { tokenSetMatches(stepTokens, word: $0) }
                if !stepHasIngQualifier {
                    if stepHasCompetingQualifier(stepWords: stepWords, headNoun: head, allowedQualifiers: ingQualifiers, allQualifiers: qualifiers) {
                        candidateWords.removeAll { $0 == head || $0 == head + "s" || String($0.dropLast()) == head }
                    }
                    if ["sauce", "milk", "paste"].contains(head) {
                        candidateWords.removeAll { $0 == head }
                    }
                    // If this is a qualified garnish ingredient (e.g. "green onions to garnish") and the step
                    // neither mentions the qualifier ("green") nor is a garnish/final step, do not match on bare head ("onions").
                    if isGarnishIngredient && !isFinalStep && stepTokens.isDisjoint(with: garnishStepKeywords) {
                        candidateWords.removeAll { $0 == head || $0 == head + "s" || String($0.dropLast()) == head }
                    }
                }
            }
        }

        // 4. Bound Compound Modifier Suppression:
        let compoundHeads: Set<String> = [
            "sauce", "sauces", "butter", "oil", "oils", "vinegar", "milk", "cream", "paste",
            "powder", "flour", "broth", "stock", "extract", "dressing", "syrup", "starch"
        ]

        for word in candidateWords {
            if stepContainsUnboundMatch(stepWords: stepWords, word: word, ingTokenSet: ingTokenSet, compoundHeads: compoundHeads) {
                return true
            }
        }
        return false
    }

    private static func stepContainsModifierBeforeHead(
        stepWords: [String],
        modifier: String,
        heads: Set<String>
    ) -> Bool {
        for (idx, w) in stepWords.enumerated() where tokenSetMatches([w], word: modifier) {
            let maxLookahead = min(stepWords.count - 1, idx + 3)
            if idx + 1 <= maxLookahead {
                for nextIdx in (idx + 1)...maxLookahead {
                    let nextWord = stepWords[nextIdx]
                    if heads.contains(where: { tokenSetMatches([nextWord], word: $0) }) {
                        return true
                    }
                }
            }
        }
        return false
    }

    private static func stripEditorialNotes(_ text: String) -> String {
        // Strip parenthetical prep, substitution, measurement, or editorial notes: e.g.
        // "(cut into 2-inch chunks, excess fat removed)", "(or two small-medium, cut into 2-inch chunks)",
        // "(see note 2)", "(to garnish)".
        var result = text
        if let parenRegex = try? NSRegularExpression(pattern: #"\([^)]*\)"#, options: [.caseInsensitive]) {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            let stripped = parenRegex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: " ")
            if stripped.contains(where: { $0.isLetter }) {
                result = stripped
            }
        }
        if let roleRegex = try? NSRegularExpression(pattern: #"\b(?:to\s+garnish|for\s+garnish|to\s+serve|for\s+serving|for\s+topping|see\s+note\s*\d*)\b"#, options: [.caseInsensitive]) {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = roleRegex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: " ")
        }
        return result
    }

    private static func significantIngredientTokens(_ ingredientLine: String) -> [String] {
        let normalizedIng = stripEditorialNotes(normalizeText(ingredientLine))
        let stopWords: Set<String> = [
            "cup", "cups", "tbsp", "tablespoon", "tablespoons", "tsp", "teaspoon", "teaspoons",
            "oz", "ounce", "ounces", "lb", "lbs", "pound", "pounds", "gram", "grams", "kg", "ml",
            "liter", "liters", "pinch", "dash", "clove", "cloves", "slice", "slices", "can", "cans",
            "package", "packages", "large", "medium", "small", "fresh", "freshly", "dried", "ground",
            "coarse", "coarsely", "chopped", "minced", "diced", "sliced", "warm", "cold", "hot",
            "room", "temperature", "optional", "to", "taste", "and", "or", "of", "the", "a", "an",
            "for", "with", "into", "in", "from", "all", "purpose", "gluten", "free", "non",
            "unsalted", "salted", "extra", "virgin", "active", "dry", "whole", "half", "cut", "peeled",
            "deveined", "melted", "softened", "beaten", "divided", "plus", "more", "about", "each",
            "finely", "roughly", "thinly", "thickly", "cubed", "grated", "shredded", "crushed",
            "packed", "heaping", "level", "scant", "box", "bag", "jar", "bottle", "bunch", "sprig",
            "sprigs", "head", "heads", "stalk", "stalks", "piece", "pieces", "strip", "strips",
            "chunk", "chunks", "leaf", "leaves", "quart", "quarts", "pint", "pints",
            "raw", "cooked", "frozen", "thawed", "rinsed", "drained", "pitted", "seeded", "cored",
            "trimmed", "halved", "quartered", "lengthwise", "crosswise", "inch", "inches",
            "garnish", "serving", "serve", "see", "note", "notes", "lean", "excess", "fat", "removed",
            "uncooked", "boneless", "skinless", "fire", "roasted", "smoked", "one", "two", "three",
            "four", "five", "six", "seven", "eight", "nine", "ten"
        ]
        return normalizedIng
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 && !stopWords.contains($0) && !$0.allSatisfy({ $0.isNumber }) }
    }

    private static func stepContainsUnboundMatch(
        stepWords: [String],
        word: String,
        ingTokenSet: Set<String>,
        compoundHeads: Set<String>
    ) -> Bool {
        for (idx, stepWord) in stepWords.enumerated() {
            if tokenSetMatches([stepWord], word: word) {
                // If `stepWord` is immediately followed by a compound head noun (e.g. "peanut" + "sauce" or "peanut" + "butter"),
                // check if the ingredient itself contains that compound head noun.
                if idx + 1 < stepWords.count {
                    let nextWord = stepWords[idx + 1]
                    if compoundHeads.contains(nextWord) && !tokenSetMatches([stepWord], word: nextWord) {
                        let ingHasThatHead = ingTokenSet.contains { tokenSetMatches([nextWord], word: $0) }
                        if !ingHasThatHead {
                            // This occurrence in the step is bound to a different compound (e.g. "peanut sauce" / "peanut butter");
                            // keep scanning in case `word` also appears unbound later in the step.
                            continue
                        }
                    }
                }
                return true
            }
        }
        return false
    }

    private static func normalizeText(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
    }

    private static func tokenSetMatches(_ stepTokens: Set<String>, word: String) -> Bool {
        if stepTokens.contains(word) { return true }
        if stepTokens.contains(word + "s") || stepTokens.contains(word + "es") || stepTokens.contains(word + "d") || stepTokens.contains(word + "ed") {
            return true
        }
        if word.hasSuffix("s") {
            let base = String(word.dropLast())
            if stepTokens.contains(base) || stepTokens.contains(base + "d") { return true }
        }
        if word.hasSuffix("es") {
            let base = String(word.dropLast(2))
            if stepTokens.contains(base) || stepTokens.contains(base + "d") { return true }
        }
        if word.hasSuffix("d") && word.count >= 5 {
            let base = String(word.dropLast())
            if stepTokens.contains(base) || stepTokens.contains(base + "s") { return true }
        }
        if word.hasSuffix("ed") && word.count >= 6 {
            let base = String(word.dropLast(2))
            if stepTokens.contains(base) || stepTokens.contains(base + "s") { return true }
        }
        if word.hasSuffix("ies") && stepTokens.contains(String(word.dropLast(3)) + "y") { return true }
        if word.hasSuffix("y") && stepTokens.contains(String(word.dropLast()) + "ies") { return true }

        // Typo-tolerant match for longer culinary nouns (e.g. "avocado" <-> "avacados", "jalapeno" <-> "jalepeno", "mayonnaise" <-> "mayonaise"):
        // Requires singular stems of >= 6 chars that share the same 2-character prefix and final character with edit distance <= 1.
        let wStem = singularStem(word)
        if wStem.count >= 6 {
            let wPrefix = wStem.prefix(2)
            let wLast = wStem.last
            for tok in stepTokens {
                let tStem = singularStem(tok)
                guard tStem.count >= 6,
                      abs(wStem.count - tStem.count) <= 1,
                      tStem.prefix(2) == wPrefix,
                      tStem.last == wLast else {
                    continue
                }
                if isWithinOneEdit(wStem, tStem) {
                    return true
                }
            }
        }
        return false
    }

    private static func singularStem(_ word: String) -> String {
        if word.hasSuffix("ies") && word.count > 4 {
            return String(word.dropLast(3)) + "y"
        }
        if word.hasSuffix("s") && !word.hasSuffix("ss") && word.count > 4 {
            return String(word.dropLast())
        }
        return word
    }

    private static func isWithinOneEdit(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let aChars = Array(a)
        let bChars = Array(b)
        let n = aChars.count
        let m = bChars.count
        if abs(n - m) > 1 { return false }
        var i = 0
        var j = 0
        var edits = 0
        while i < n && j < m {
            if aChars[i] == bChars[j] {
                i += 1
                j += 1
            } else {
                edits += 1
                if edits > 1 { return false }
                if n > m {
                    i += 1
                } else if m > n {
                    j += 1
                } else {
                    i += 1
                    j += 1
                }
            }
        }
        if i < n || j < m {
            edits += 1
        }
        return edits <= 1
    }

    private static func stepHasCompetingQualifier(
        stepWords: [String],
        headNoun: String,
        allowedQualifiers: Set<String>,
        allQualifiers: Set<String>
    ) -> Bool {
        for (idx, w) in stepWords.enumerated() where idx > 0 {
            if w == headNoun || w == headNoun + "s" || (headNoun.hasSuffix("s") && w == String(headNoun.dropLast())) {
                let prev = stepWords[idx - 1]
                if allQualifiers.contains(prev) && !allowedQualifiers.contains(prev) {
                    return true
                }
            }
        }
        return false
    }

    private func currentStepMentionsIngredient(_ ingredientLine: String) -> Bool {
        guard currentStepIndex >= 0, currentStepIndex < steps.count else { return false }
        return Self.stepMentionsIngredient(stepText: steps[currentStepIndex].text, ingredientLine: ingredientLine)
    }

    // MARK: - Steps Column

    private var stepsColumn: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if isFinished {
                        completionCard
                            .id("step-finished")
                    }

                    ForEach(Array(steps.enumerated()), id: \.offset) { idx, step in
                        stepCard(step: step, index: idx)
                            .id("step-\(idx)")
                    }
                }
                .padding(24)
            }
            .onChange(of: currentStepIndex) { _, newIdx in
                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                    if newIdx >= steps.count {
                        proxy.scrollTo("step-finished", anchor: .top)
                    } else {
                        proxy.scrollTo("step-\(newIdx)", anchor: .center)
                    }
                }
            }
        }
    }

    private func stepCard(step: RecipeInstruction, index: Int) -> some View {
        let isActive = !isFinished && index == currentStepIndex
        let isCompleted = completedSteps.contains(index) || index < currentStepIndex

        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(isActive ? Color.orange : (isCompleted ? Color.green.opacity(0.2) : Color.primary.opacity(0.08)))
                        .frame(width: isActive ? 42 : 32, height: isActive ? 42 : 32)

                    if isCompleted && !isActive {
                        Image(systemName: "checkmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.green)
                    } else {
                        Text("\(step.stepNumber)")
                            .font(.system(size: isActive ? 19 : 15, weight: .bold, design: .rounded))
                            .foregroundStyle(isActive ? .white : .secondary)
                    }
                }

                if let sec = step.section, !sec.isEmpty {
                    Text(sec.uppercased())
                        .font(.system(size: 13, weight: .bold))
                        .kerning(0.6)
                        .foregroundStyle(.orange)
                }

                if let title = step.displayTitle, !title.isEmpty {
                    Text(title)
                        .font(.system(size: isActive ? 21 : 17, weight: isActive ? .bold : .semibold))
                        .foregroundStyle(isActive ? .primary : .secondary)
                }

                Spacer()

                if isActive {
                    Text("CURRENT STEP")
                        .font(.system(size: 12, weight: .bold))
                        .kerning(0.8)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.orange.opacity(0.2), in: Capsule())
                        .foregroundStyle(.orange)
                }
            }

            Text(step.text)
                .font(.system(size: isActive ? 26 : 17, weight: isActive ? .medium : .regular))
                .foregroundStyle(isActive ? .primary : .secondary)
                .lineSpacing(isActive ? 7 : 4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, isActive ? 54 : 44)

            if isActive {
                let matchedSorted = activeMatchedIngredientIndices.sorted()
                if !matchedSorted.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 6) {
                            Image(systemName: "flame.fill")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.orange)
                            Text("INGREDIENTS FOR THIS STEP (CLICK TO CHECK OFF)")
                                .font(.system(size: 12, weight: .bold))
                                .kerning(0.5)
                                .foregroundStyle(.orange)
                        }

                        FlowLayout(spacing: 8) {
                            ForEach(matchedSorted, id: \.self) { ingIdx in
                                if ingIdx >= 0 && ingIdx < recipe.ingredients.count {
                                    let ing = recipe.ingredients[ingIdx]
                                    let key = "\(ingIdx)-\(ing.text)"
                                    let isChecked = checkedIngredients.contains(key)

                                    Button {
                                        if isChecked {
                                            checkedIngredients.remove(key)
                                        } else {
                                            checkedIngredients.insert(key)
                                        }
                                    } label: {
                                        HStack(spacing: 7) {
                                            Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                                                .font(.system(size: 15))
                                                .foregroundStyle(isChecked ? Color.green : Color.orange)
                                            Text(ing.text)
                                                .font(.system(size: 15, weight: .semibold))
                                                .strikethrough(isChecked, color: .secondary)
                                                .foregroundStyle(isChecked ? .secondary : .primary)
                                        }
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 7)
                                        .background(
                                            RoundedRectangle(cornerRadius: 8)
                                                .fill(Color(nsColor: .controlBackgroundColor))
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8)
                                                .strokeBorder(Color.orange.opacity(isChecked ? 0.25 : 0.55), lineWidth: 1)
                                        )
                                        .opacity(isChecked ? 0.65 : 1.0)
                                    }
                                    .buttonStyle(.plain)
                                    .focusable(false)
                                }
                            }
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.orange.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
                    )
                    .padding(.leading, 54)
                    .padding(.top, 4)
                }
            }
        }
        .padding(isActive ? 24 : 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isActive ? Color.orange.opacity(0.10) : Color(nsColor: .controlBackgroundColor).opacity(isCompleted ? 0.5 : 0.8))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isActive ? Color.orange : Color.primary.opacity(0.07), lineWidth: isActive ? 2 : 1)
        )
        .scaleEffect(isActive ? 1.0 : 0.985)
        .opacity(isActive ? 1.0 : (isCompleted ? 0.65 : 0.80))
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: isActive)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                currentStepIndex = index
            }
        }
    }

    private var cookLogPromptSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                logAsCooked.toggle()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: logAsCooked ? "checkmark.square.fill" : "square")
                        .font(.system(size: 20))
                        .foregroundStyle(logAsCooked ? Color.green : Color.secondary)
                    Text("Log recipe as cooked")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text("(adds #cooked tag & Cook Log entry)")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)

            if logAsCooked {
                HStack(spacing: 14) {
                    HStack(spacing: 5) {
                        Text("Rating:")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.secondary)
                        ForEach(1...5, id: \.self) { star in
                            Button {
                                cookRating = (cookRating == star) ? 0 : star
                            } label: {
                                Image(systemName: star <= cookRating ? "star.fill" : "star")
                                    .font(.system(size: 18))
                                    .foregroundStyle(star <= cookRating ? Color.orange : Color.secondary.opacity(0.45))
                            }
                            .buttonStyle(.plain)
                            .focusable(false)
                        }
                    }

                    FilterField(
                        placeholder: "Optional cook note (e.g. doubled garlic, 25m)…",
                        text: $cookNote
                    )
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.green.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.green.opacity(0.35), lineWidth: 1)
        )
    }

    private func finishCookingAndDismiss() {
        if logAsCooked && !hasLoggedSession {
            hasLoggedSession = true
            let finalRating = cookRating > 0 ? cookRating : nil
            let trimmedNote = cookNote.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalNote = trimmedNote.isEmpty ? nil : trimmedNote
            onFinishCooking?(finalRating, finalNote)
        }
        dismiss()
    }

    private var completionCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)

            Text("Bon Appétit!")
                .font(.title2.weight(.bold))

            Text("You've completed all \(totalSteps) steps of \(recipe.title).")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("Restart from Step 1") {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                        completedSteps.removeAll()
                        currentStepIndex = 0
                    }
                }
                .buttonStyle(.bordered)
                .focusable(false)

                Button("Done Cooking") {
                    finishCookingAndDismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .focusable(false)
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.green.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.green.opacity(0.35), lineWidth: 1.5)
        )
    }

    // MARK: - Footer

    private var wizardFooter: some View {
        VStack(alignment: .leading, spacing: 12) {
            if totalSteps > 0 && (currentStepIndex == totalSteps - 1 || isFinished) {
                cookLogPromptSection
            }

            HStack(spacing: 16) {
                Button {
                    previousStep()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                        Text("Previous")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(currentStepIndex <= 0)
                .focusable(false)

                Spacer()

                HStack(spacing: 6) {
                    Text("Press")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Text("Space")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
                    Text("for next step •")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Text("← / →")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
                    Text("to navigate •")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Text("S")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
                    Text("to speak")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if isFinished {
                    Button {
                        finishCookingAndDismiss()
                    } label: {
                        Text("Finish")
                            .font(.system(size: 15, weight: .semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(.green)
                    .focusable(false)
                } else {
                    Button {
                        if currentStepIndex == totalSteps - 1 {
                            finishCookingAndDismiss()
                        } else {
                            nextStep()
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(currentStepIndex == totalSteps - 1 ? "Finish Cooking" : "Next Step")
                                .font(.system(size: 15, weight: .semibold))
                            Image(systemName: currentStepIndex == totalSteps - 1 ? "checkmark" : "chevron.right")
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(.orange)
                    .focusable(false)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Step Navigation & Spacebar Monitor

    private func nextStep() {
        guard totalSteps > 0 else { return }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
            if currentStepIndex < totalSteps {
                completedSteps.insert(currentStepIndex)
                currentStepIndex += 1
            } else {
                dismiss()
            }
        }
    }

    private func previousStep() {
        guard currentStepIndex > 0 else { return }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
            if isFinished {
                currentStepIndex = totalSteps - 1
            } else {
                currentStepIndex -= 1
            }
        }
    }

    private func installKeyboardMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let isEditingText: Bool = MainActor.assumeIsolated {
                guard let responder = NSApp.keyWindow?.firstResponder else { return false }
                return responder is NSTextView || responder is NSTextField
            }
            if isEditingText {
                if event.keyCode == 53 { // Escape resigns first responder from text input
                    MainActor.assumeIsolated {
                        _ = NSApp.keyWindow?.makeFirstResponder(nil)
                    }
                    return nil
                }
                return event
            }

            // Spacebar (keyCode 49)
            if event.keyCode == 49 {
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if flags.contains(.shift) {
                    MainActor.assumeIsolated { previousStep() }
                } else {
                    MainActor.assumeIsolated { nextStep() }
                }
                return nil // Consume spacebar so it never triggers underlying list QuickLook
            }
            // Right arrow (124) or Down arrow (125)
            if event.keyCode == 124 || event.keyCode == 125 {
                MainActor.assumeIsolated { nextStep() }
                return nil
            }
            // Left arrow (123) or Up arrow (126)
            if event.keyCode == 123 || event.keyCode == 126 {
                MainActor.assumeIsolated { previousStep() }
                return nil
            }
            // 'S' key (keyCode 1) -> Speak / Stop current step
            if event.keyCode == 1 {
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if !flags.contains(.command) && !flags.contains(.control) && !flags.contains(.option) {
                    MainActor.assumeIsolated { toggleSpeakCurrentStep() }
                    return nil
                }
            }
            // Escape (53)
            if event.keyCode == 53 {
                MainActor.assumeIsolated { dismiss() }
                return nil
            }
            return event
        }
    }

    private func removeKeyboardMonitor() {
        if let m = keyMonitor {
            NSEvent.removeMonitor(m)
            keyMonitor = nil
        }
    }

    private func acquireDisplaySleepAssertion() {
        if processActivityToken == nil {
            processActivityToken = ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled, .userInitiated],
                reason: "Stash Cooking Assistant Wizard active"
            )
        }
        if sleepAssertionID == 0 {
            var assertionID: IOPMAssertionID = 0
            let status = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Stash Cooking Assistant Wizard" as CFString,
                &assertionID
            )
            if status == kIOReturnSuccess {
                sleepAssertionID = assertionID
            }
        }
    }

    private func releaseDisplaySleepAssertion() {
        if let token = processActivityToken {
            ProcessInfo.processInfo.endActivity(token)
            processActivityToken = nil
        }
        if sleepAssertionID != 0 {
            IOPMAssertionRelease(sleepAssertionID)
            sleepAssertionID = 0
        }
    }
}
