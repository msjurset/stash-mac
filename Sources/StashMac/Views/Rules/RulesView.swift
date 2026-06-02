import SwiftUI

/// Middle column of the Rules navigation. Shows the rule list with action
/// chips per row; selecting a row populates the detail pane (right column)
/// via `store.selectedRuleName`. New rules are created via the toolbar
/// "+" button which seeds a draft and selects it for editing.
struct RulesView: View {
    @Environment(StashStore.self) private var store
    @State private var filterText: String = ""
    @State private var showDisabled: Bool = true
    @State private var suggestSheetPresented: Bool = false

    private var filteredRules: [Rule] {
        let needle = filterText.trimmingCharacters(in: .whitespaces).lowercased()
        return store.rules.filter { rule in
            if !showDisabled && !rule.isEnabled { return false }
            if needle.isEmpty { return true }
            if rule.name.lowercased().contains(needle) { return true }
            if let d = rule.description, d.lowercased().contains(needle) { return true }
            if rule.match.summary.lowercased().contains(needle) { return true }
            for action in rule.actions ?? [] {
                if let tags = action.addTags,
                   tags.contains(where: { $0.lowercased().contains(needle) }) {
                    return true
                }
                if let v = action.addCollection, v.lowercased().contains(needle) { return true }
            }
            return false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Rules")
        .toolbar {
            ToolbarItem {
                Button {
                    store.startNewRuleDraft()
                } label: {
                    Label("New Rule", systemImage: "plus")
                }
                .help("Create a new rule")
            }
            ToolbarItem {
                Button {
                    suggestSheetPresented = true
                } label: {
                    Label("Suggest", systemImage: "sparkles")
                }
                .help("Analyze recently captured items and suggest new rules")
            }
            ToolbarItem {
                Button {
                    store.loadRules()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Reload rules from ~/.stash/rules.yaml")
                .disabled(store.rulesLoading)
            }
            ToolbarItem {
                ContextualHelpButton(topic: .rules, isToolbarItem: true)
            }
        }
        .sheet(isPresented: $suggestSheetPresented) {
            SuggestRulesSheet()
        }
        .task { store.loadRules() }
    }

    private var suggestHelpText: String {
        if let reason = RuleSuggestionService.shared.unavailabilityReason {
            return "Suggest rules from recent tagging — \(reason)"
        }
        return "Suggest rules from recent tagging (on-device Apple Intelligence)"
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.callout)
            FilterField(placeholder: "Filter by name, description, tag, match…", text: $filterText)
            if !filterText.isEmpty {
                Button {
                    filterText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear filter")
            }
            Toggle(isOn: $showDisabled) {
                Text("Show disabled")
                    .font(.caption)
            }
            .toggleStyle(.checkbox)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if store.rulesLoading && store.rules.isEmpty {
            ProgressView("Loading rules...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let err = store.rulesError, store.rules.isEmpty {
            ContentUnavailableView {
                Label("Couldn't load rules", systemImage: "exclamationmark.triangle")
            } description: {
                Text(err)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.rules.isEmpty {
            emptyState
        } else if filteredRules.isEmpty && store.draftRule == nil {
            ContentUnavailableView(
                "No matches",
                systemImage: "line.3.horizontal.decrease.circle",
                description: Text("No rules match \"\(filterText)\".")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            rulesList
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Rules", systemImage: "wand.and.stars")
        } description: {
            VStack(spacing: 8) {
                Text("Create your first rule to start tagging items automatically as they're stashed.")
                Text("Rules can also set titles, append notes, fire notifications, link items, or skip noise.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("New Rule") {
                    store.startNewRuleDraft()
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var rulesList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if let draft = store.draftRule {
                    RuleRow(rule: draft, isSelected: store.selectedRuleName == "__new__", isDraft: true)
                        .onTapGesture {
                            store.selectedRuleName = "__new__"
                        }
                }
                ForEach(filteredRules) { rule in
                    RuleRow(rule: rule, isSelected: store.selectedRuleName == rule.name, isDraft: false)
                        .onTapGesture {
                            store.selectedRuleName = rule.name
                        }
                        .contextMenu {
                            Button(rule.isEnabled ? "Disable" : "Enable") {
                                store.setRuleEnabled(name: rule.name, enabled: !rule.isEnabled)
                            }
                            Divider()
                            Button("Delete", role: .destructive) {
                                store.deleteRule(name: rule.name)
                            }
                        }
                }
            }
            .padding(10)
        }
    }
}

/// One rule row in the list. Renders name, optional SKIP badge, match
/// summary, and action chips. Selection state drives a tinted background.
private struct RuleRow: View {
    let rule: Rule
    let isSelected: Bool
    let isDraft: Bool

    private var hasSkipAction: Bool {
        rule.actions?.contains(where: { $0.skip == true }) ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(isDraft ? "(new rule)" : rule.name)
                    .font(.headline)
                    .foregroundStyle(isDraft ? .secondary : .primary)
                if hasSkipAction {
                    Text("SKIP")
                        .font(.caption2.bold())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.red.opacity(0.18), in: Capsule())
                        .foregroundStyle(.red)
                }
                if !rule.isEnabled && !isDraft {
                    Text("DISABLED")
                        .font(.caption2.bold())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.gray.opacity(0.18), in: Capsule())
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if let desc = rule.description, !desc.isEmpty {
                Text(taggedAttributedString(desc))
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(0.85))
                    .lineLimit(2)
            }

            Text(rule.match.summary.isEmpty ? "(no match conditions)" : rule.match.summary)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)

            actionChips
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.18)) : AnyShapeStyle(.quaternary.opacity(0.5)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1)
        )
        .opacity(rule.isEnabled || isDraft ? 1.0 : 0.6)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var actionChips: some View {
        let actions = rule.actions ?? []
        FlowLayout(spacing: 4) {
            ForEach(actions.indices, id: \.self) { i in
                let action = actions[i]
                if let tags = action.addTags, !tags.isEmpty {
                    ForEach(tags, id: \.self) { tag in
                        Chip("#\(tag)", color: .blue)
                    }
                }
                if let coll = action.addCollection, !coll.isEmpty {
                    Chip(coll, icon: "folder", color: .orange)
                }
                if let title = action.setTitle, !title.isEmpty {
                    Chip("title", icon: "textformat", color: .purple)
                }
                if let note = action.setNote, !note.isEmpty {
                    Chip("note", icon: "note.text", color: .gray)
                }
                if let appended = action.appendNote, !appended.isEmpty {
                    Chip("+note", icon: "plus.bubble", color: .gray)
                }
                if let n = action.notify, !n.isEmpty {
                    Chip("notify", icon: "bell", color: .yellow)
                }
                if let l = action.linkTo {
                    if let tag = l.tag, !tag.isEmpty {
                        Chip("link → #\(tag)", icon: "link", color: .teal)
                    } else if let id = l.id, !id.isEmpty {
                        Chip("link → \(id.prefix(8))", icon: "link", color: .teal)
                    }
                }
            }
        }
    }
}

/// Tiny rounded-capsule label used for action chips in the rules list.
private struct Chip: View {
    let text: String
    var icon: String? = nil
    let color: Color

    init(_ text: String, icon: String? = nil, color: Color) {
        self.text = text
        self.icon = icon
        self.color = color
    }

    var body: some View {
        HStack(spacing: 3) {
            if let icon {
                Image(systemName: icon)
                    .font(.caption2)
            }
            Text(text)
                .font(.caption)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.15), in: Capsule())
        .foregroundStyle(color)
    }
}
