import SwiftUI
import AppKit

/// Uniform, distraction-free Recipe Card displayed in the detail pane for any item
/// with extracted `RecipeData` metadata. Strips away blog preamble, ads, and clutter
/// so every recipe in Stash shares a clean, scannable layout with interactive
/// ingredient checklists and a one-click "Start Cooking" wizard launcher.
struct RecipeCardView: View {
    @Environment(StashStore.self) private var store
    @Environment(AIPrefsStore.self) private var aiPrefs

    let item: StashItem
    let recipe: RecipeData
    var onStartCooking: () -> Void
    var onClose: (() -> Void)? = nil

    @State private var checkedIngredients: Set<String> = []
    @State private var copiedFeedback = false
    @State private var isRefreshingRecipe = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardHeader

            if hasMetaStrip {
                Divider()
                metaStrip
            }

            Divider()

            // Main body: Ingredients + Instructions inside a ScrollView for popover/popout presentation
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !recipe.ingredients.isEmpty {
                        ingredientsSection
                    }

                    if !recipe.ingredients.isEmpty && !recipe.instructions.isEmpty {
                        Divider()
                    }

                    if !recipe.instructions.isEmpty {
                        instructionsSection
                    }

                    if let nutrition = recipe.nutrition, !nutrition.isEmpty {
                        Divider()
                        nutritionSection(nutrition)
                    }

                    if !recipe.cookHistory.isEmpty {
                        Divider()
                        cookLogSection
                    }
                }
                .padding(18)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.orange.opacity(0.3), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.06), radius: 6, x: 0, y: 2)
    }

    // MARK: - Header

    private var cardHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "fork.knife")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.orange)
                        Text("RECIPE CARD")
                            .font(.system(size: 10, weight: .bold))
                            .kerning(0.8)
                            .foregroundStyle(.orange)
                        if let cuisine = recipe.cuisine, !cuisine.isEmpty {
                            Text("•")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Text(cuisine.uppercased())
                                .font(.system(size: 10, weight: .semibold))
                                .kerning(0.5)
                                .foregroundStyle(.secondary)
                        }
                        if let category = recipe.category, !category.isEmpty {
                            Text("•")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Text(category.uppercased())
                                .font(.system(size: 10, weight: .semibold))
                                .kerning(0.5)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text(recipe.title)
                        .font(.system(size: 21, weight: .bold))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)

                    if let author = recipe.author, !author.isEmpty {
                        Text("By \(author)")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                HStack(spacing: 10) {
                    if !recipe.instructions.isEmpty {
                        Button(action: onStartCooking) {
                            HStack(spacing: 6) {
                                Image(systemName: "flame.fill")
                                    .font(.system(size: 14, weight: .semibold))
                                Text("Start Cooking")
                                    .font(.system(size: 14, weight: .semibold))
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.orange, in: Capsule())
                            .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                        .focusable(false)
                        .pointingHandCursor()
                        .help("Open step-by-step Cooking Assistant (advance steps with Spacebar)")
                    }

                    Menu {
                        Button {
                            if RecipePDFGenerator.copyPDFToClipboard(for: recipe, item: item) {
                                triggerCopiedFeedback(message: "Copied Recipe PDF")
                            }
                        } label: {
                            Label("Copy Recipe PDF", systemImage: "doc.richtext")
                        }
                        Button {
                            RecipePDFGenerator.savePDFWithPanel(for: recipe, item: item)
                        } label: {
                            Label("Save Recipe PDF…", systemImage: "arrow.down.doc")
                        }
                        Button {
                            RecipePDFGenerator.presentShareSheet(for: recipe, item: item)
                        } label: {
                            Label("Share Recipe PDF…", systemImage: "square.and.arrow.up")
                        }
                        Divider()
                        Button {
                            copyToClipboard(recipe.formattedIngredientsPlaintext)
                        } label: {
                            Label("Copy Ingredients List", systemImage: "list.bullet.clipboard")
                        }
                        Button {
                            copyToClipboard(recipe.formattedMarkdown)
                        } label: {
                            Label("Copy Full Recipe (Markdown)", systemImage: "doc.on.doc")
                        }
                        if !checkedIngredients.isEmpty {
                            Divider()
                            Button("Uncheck All Ingredients") {
                                checkedIngredients.removeAll()
                            }
                        }
                        Divider()
                        Button {
                            isRefreshingRecipe = true
                            Task {
                                _ = await store.extractRecipeForItem(item, prefs: aiPrefs)
                                isRefreshingRecipe = false
                            }
                        } label: {
                            Label("Re-extract Recipe", systemImage: "arrow.clockwise")
                        }
                        Button(role: .destructive) {
                            Task {
                                await store.removeRecipe(for: item.id)
                            }
                        } label: {
                            Label("Remove Recipe Card", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: copiedFeedback ? "checkmark.circle.fill" : "square.and.arrow.up.circle")
                            .font(.title3)
                            .foregroundStyle(copiedFeedback ? .green : .secondary)
                            .frame(width: 24, height: 24)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .focusable(false)
                    .help("Share or export Recipe PDF")

                    if let onClose {
                        Button(action: onClose) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.plain)
                        .focusable(false)
                        .pointingHandCursor()
                        .help("Close Recipe Card (Esc)")
                    }
                }
            }

            if let desc = recipe.description, !desc.isEmpty {
                Text(desc)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
        }
        .padding(18)
        .background(Color.orange.opacity(0.05))
    }

    // MARK: - Metadata Strip

    private var hasMetaStrip: Bool {
        (recipe.prepTime?.isEmpty == false) ||
        (recipe.cookTime?.isEmpty == false) ||
        (recipe.totalTime?.isEmpty == false) ||
        (recipe.yield?.isEmpty == false) ||
        !recipe.cookHistory.isEmpty
    }

    private var cookedSummaryValue: String? {
        guard let last = recipe.cookHistory.last else { return nil }
        let count = recipe.cookHistory.count
        if count == 1 {
            return "1× (\(last.formattedDate))"
        }
        return "\(count)× (last \(last.formattedDate))"
    }

    private var metaStrip: some View {
        HStack(spacing: 24) {
            if let prep = recipe.prepTime, !prep.isEmpty {
                metaBadge(icon: "clock", label: "PREP TIME", value: prep)
            }
            if let cook = recipe.cookTime, !cook.isEmpty {
                metaBadge(icon: "flame", label: "COOK TIME", value: cook)
            }
            if let total = recipe.totalTime, !total.isEmpty {
                metaBadge(icon: "hourglass", label: "TOTAL TIME", value: total)
            }
            if let yld = recipe.yield, !yld.isEmpty {
                metaBadge(icon: "person.2", label: "YIELD", value: yld)
            }
            if let cooked = cookedSummaryValue {
                metaBadge(icon: "checkmark.seal.fill", label: "COOKED", value: cooked)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.02))
    }

    private func metaBadge(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                Text(value)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
            }
        }
    }

    // MARK: - Ingredients

    private var ingredientsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Ingredients", systemImage: "basket.fill")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text("(\(recipe.ingredients.count))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                if !checkedIngredients.isEmpty {
                    Button("Clear (\(checkedIngredients.count))") {
                        checkedIngredients.removeAll()
                    }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .focusable(false)
                }
            }

            let grouped = groupIngredients(recipe.ingredients)
            VStack(alignment: .leading, spacing: 12) {
                ForEach(grouped, id: \.section) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        if let sec = group.section, !sec.isEmpty {
                            Text(sec)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.orange)
                                .padding(.top, 2)
                        }
                        ForEach(Array(group.items.enumerated()), id: \.offset) { idx, ing in
                            let key = "\(group.section ?? "")-\(idx)-\(ing.text)"
                            let isChecked = checkedIngredients.contains(key)
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 16))
                                    .foregroundStyle(isChecked ? Color.orange : Color.secondary.opacity(0.6))
                                    .padding(.top, 1)
                                Text(ing.text)
                                    .font(.system(size: 15))
                                    .strikethrough(isChecked, color: .secondary)
                                    .foregroundStyle(isChecked ? .secondary : .primary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 3)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if isChecked {
                                    checkedIngredients.remove(key)
                                } else {
                                    checkedIngredients.insert(key)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private struct IngredientGroup {
        let section: String?
        let items: [RecipeIngredient]
    }

    private func groupIngredients(_ list: [RecipeIngredient]) -> [IngredientGroup] {
        var groups: [IngredientGroup] = []
        var currentSection: String? = nil
        var currentItems: [RecipeIngredient] = []

        for item in list {
            if item.section != currentSection && !currentItems.isEmpty {
                groups.append(IngredientGroup(section: currentSection, items: currentItems))
                currentItems = []
            }
            currentSection = item.section
            currentItems.append(item)
        }
        if !currentItems.isEmpty {
            groups.append(IngredientGroup(section: currentSection, items: currentItems))
        }
        return groups
    }

    // MARK: - Instructions

    private var instructionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Instructions", systemImage: "list.number")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text("(\(recipe.instructions.count) steps)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(recipe.instructions.enumerated()), id: \.offset) { idx, step in
                    VStack(alignment: .leading, spacing: 6) {
                        if let sec = step.section, !sec.isEmpty,
                           (idx == 0 || recipe.instructions[idx - 1].section != sec) {
                            Text(sec)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.orange)
                                .padding(.top, 4)
                        }

                        HStack(alignment: .top, spacing: 12) {
                            Text("\(step.stepNumber)")
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .foregroundStyle(.orange)
                                .frame(width: 28, height: 28)
                                .background(Color.orange.opacity(0.14), in: Circle())

                            VStack(alignment: .leading, spacing: 4) {
                                if let title = step.displayTitle, !title.isEmpty {
                                    Text(title)
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(.primary)
                                }
                                Text(step.text)
                                    .font(.system(size: 15))
                                    .foregroundStyle(.primary.opacity(0.92))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .lineSpacing(3)
                                    .textSelection(.enabled)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Nutrition

    private func nutritionSection(_ nutrition: [String: String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("NUTRITION")
                .font(.system(size: 10, weight: .bold))
                .kerning(0.6)
                .foregroundStyle(.secondary)

            FlowLayout(spacing: 8) {
                ForEach(nutrition.keys.sorted(), id: \.self) { key in
                    if let val = nutrition[key] {
                        HStack(spacing: 4) {
                            Text(key.capitalized + ":")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(val)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.primary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.primary.opacity(0.05), in: Capsule())
                    }
                }
            }
        }
    }

    // MARK: - Cook Log

    private var cookLogSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Label("Cook Log", systemImage: "flame.fill")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text("(\(recipe.cookHistory.count))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(recipe.cookHistory.reversed())) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                            Text(entry.formattedDate)
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.primary)
                            if let stars = entry.formattedStars {
                                Text(stars)
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                            Spacer()
                        }
                        if let note = entry.note, !note.isEmpty {
                            Text(note)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.leading, 20)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        triggerCopiedFeedback(message: nil)
    }

    private func triggerCopiedFeedback(message: String?) {
        if let message {
            ToastCenter.shared.show(message, kind: .success)
        }
        copiedFeedback = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            copiedFeedback = false
        }
    }
}
