import SwiftUI

/// Right-column inline editor for the currently-selected rule. Shows a
/// read-only "view mode" by default (Runbook-mac pattern); flip to "edit
/// mode" via the Edit button to mutate the rule. Saving commits via the
/// store, cancelling reverts to the rule on disk.
///
/// New rules (drafts) start in edit mode since there's nothing to view.
struct RuleDetailView: View {
    @Environment(StashStore.self) private var store

    enum Mode { case view, edit, activity }

    @State private var mode: Mode = .view
    @State private var activityIngestObserver: NSObjectProtocol?

    @State private var name: String = ""
    @State private var ruleDescription: String = ""
    @State private var enabled: Bool = true
    @State private var conditions: [MatchCondition] = [.empty]
    @State private var actionRows: [ActionRow] = []
    @State private var pristineSnapshot: String = ""
    @State private var loadedSource: String?

    /// Inline-edit state for the description in view mode. `editingDescription`
    /// flips on a double-click; `draftDescription` is the working buffer.
    /// Click-off / Enter commits via the store; Escape reverts.
    @State private var editingDescription: Bool = false
    @State private var draftDescription: String = ""

    /// Inline-edit state for the rule name in view mode. Same convention
    /// as description — double-click to edit, click-off / Enter commits,
    /// Escape reverts. Commit routes through `store.renameRule` so
    /// rules.yaml AND rules.log are updated atomically.
    @State private var editingName: Bool = false
    @State private var draftName: String = ""

    /// ID of the condition whose regex guide popover should show. Set by
    /// the value field's `onBeginEditing` only when the condition's key
    /// is a regex variant; cleared by `onEndEditing` or by the popover
    /// binding's setter when SwiftUI dismisses.
    @State private var regexGuideForID: UUID?

    /// Local NSEvent monitor that resigns first responder when the user
    /// clicks outside the focused regex condition field. Without this,
    /// clicking out only dismisses the popover (the field keeps focus),
    /// so clicking back in doesn't re-fire `becomeFirstResponder` and
    /// the popover stays hidden until you type or move focus elsewhere
    /// and back. Lifecycle: installed when `regexGuideForID` becomes
    /// non-nil, removed when it goes back to nil.
    @State private var regexClickMonitor: Any?

    private var sourceRule: Rule? {
        guard let key = store.selectedRuleName else { return nil }
        if key == "__new__" { return store.draftRule }
        return store.rules.first(where: { $0.name == key })
    }

    private var isDraft: Bool { store.selectedRuleName == "__new__" }

    private var hasUnsavedChanges: Bool {
        currentSnapshot() != pristineSnapshot
    }

    private var canSave: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty &&
            !nameCollides &&
            conditions.contains(where: { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }) &&
            !actionRows.isEmpty
    }

    /// True if the typed name collides with another existing rule. The
    /// rule's own current name doesn't count as a collision (no-op
    /// rename). Drafts have no original name so any existing match is a
    /// collision.
    private var nameCollides: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        let originalName = isDraft ? "" : (sourceRule?.name ?? "")
        if trimmed == originalName { return false }
        return store.rules.contains(where: { $0.name == trimmed })
    }

    /// Live validation status for the Name field. Drives the
    /// password-complexity-style indicator under the field — red X for
    /// invalid input, green check for a confirmed-available new name.
    private enum NameValidation {
        case unchanged           // matches original — no feedback needed
        case empty               // edited down to nothing
        case collides(String)    // typed name matches another rule
        case available           // changed, non-empty, no collision
    }

    private var nameValidation: NameValidation {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let originalName = isDraft ? "" : (sourceRule?.name ?? "")
        if trimmed == originalName { return .unchanged }
        if trimmed.isEmpty { return .empty }
        if store.rules.contains(where: { $0.name == trimmed }) {
            return .collides(trimmed)
        }
        return .available
    }

    var body: some View {
        Group {
            if sourceRule == nil {
                emptyState
            } else {
                switch mode {
                case .view:     viewMode
                case .edit:     editMode
                case .activity: activityMode
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { reloadFromSource() }
        .onChange(of: store.selectedRuleName) { _, _ in
            reloadFromSource()
        }
        .onChange(of: mode) { _, newValue in
            // When switching INTO activity, fetch events filtered to
            // this rule. Switching OUT clears the per-rule subscription
            // so we don't keep refetching when the user is editing.
            if newValue == .activity {
                if let name = sourceRule?.name {
                    store.loadRuleEvents(rule: name)
                }
                installActivityIngestObserver()
            } else {
                removeActivityIngestObserver()
            }
        }
        .onDisappear { removeActivityIngestObserver() }
        .onChange(of: regexGuideForID) { _, newValue in
            if newValue != nil {
                installRegexClickMonitor()
            } else {
                removeRegexClickMonitor()
            }
        }
        .onDisappear { removeRegexClickMonitor() }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Select a Rule", systemImage: "wand.and.stars")
        } description: {
            Text("Choose a rule from the list to view it. Use the + button at the top to create a new one.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - View mode

    private var viewMode: some View {
        VStack(alignment: .leading, spacing: 0) {
            viewHeader

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    descriptionField
                    viewMatchSection
                    viewActionsSection

                    if let err = store.rulesError {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
            }
        }
    }

    private var viewHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                nameField
                if let rule = sourceRule {
                    if !rule.isEnabled {
                        Text("DISABLED")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.gray.opacity(0.2), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                    if rule.actions?.contains(where: { $0.skip == true }) ?? false {
                        Text("SKIP")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.red.opacity(0.2), in: Capsule())
                            .foregroundStyle(.red)
                    }
                }
                Spacer()

                Button {
                    let key = store.selectedRuleName ?? ""
                    store.setRuleEnabled(name: key, enabled: !(sourceRule?.isEnabled ?? true))
                } label: {
                    Label(sourceRule?.isEnabled ?? true ? "Disable" : "Enable",
                          systemImage: sourceRule?.isEnabled ?? true ? "pause.circle" : "play.circle")
                }
                .help(sourceRule?.isEnabled ?? true ? "Disable this rule" : "Enable this rule")

                Button {
                    if let name = sourceRule?.name {
                        Task {
                            do {
                                _ = try await StashCLI.shared.applyRules(ruleName: name)
                            } catch {
                                // store.rulesError isn't quite right for this; ignore for now.
                            }
                        }
                    }
                } label: {
                    Label("Apply Now", systemImage: "play.circle.fill")
                }
                .help("Run this rule against existing items")

                Button {
                    mode = .edit
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .keyboardShortcut("e", modifiers: .command)
                .help("Edit this rule (⌘E)")
            }
            modePicker
                .padding(.top, 8)
        }
        .padding(.horizontal)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .background(.bar)
    }

    /// Underlined text tabs that swap between view-mode read-only
    /// display and the activity feed for this rule. Edit mode is
    /// reachable via the dedicated Edit button (it has its own
    /// save/cancel UX so it doesn't fit the tab metaphor cleanly).
    private var modePicker: some View {
        HStack(spacing: 18) {
            modeTab(.view, label: "Details")
            modeTab(.activity, label: "Activity")
            Spacer(minLength: 0)
        }
    }

    private func modeTab(_ target: Mode, label: String) -> some View {
        let selected = mode == target
        return Button {
            mode = target
        } label: {
            Text(label)
                .font(.footnote)
                .fontWeight(selected ? .medium : .regular)
                .foregroundStyle(selected ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                .padding(.bottom, 3)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(selected ? Color.accentColor : Color.clear)
                        .frame(height: 1.5)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Password-complexity-style indicator under the Name field in edit
    /// mode. Stays out of the way when the name matches the original (no
    /// rename in flight); flips to red X for empty/colliding inputs; flips
    /// to green check once the typed name is changed, non-empty, and
    /// unique.
    @ViewBuilder
    private var nameValidationIndicator: some View {
        switch nameValidation {
        case .unchanged:
            EmptyView()
        case .empty:
            indicatorRow(symbol: "xmark.circle.fill",
                         color: .red,
                         text: "Name can't be empty.")
        case .collides(let typed):
            indicatorRow(symbol: "xmark.circle.fill",
                         color: .red,
                         text: "Already taken — “\(typed)” is in use by another rule.")
        case .available:
            indicatorRow(symbol: "checkmark.circle.fill",
                         color: .green,
                         text: isDraft ? "Available." : "Available — saving will rename the rule.")
        }
    }

    private func indicatorRow(symbol: String, color: Color, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(color)
            Text(text)
                .foregroundStyle(color)
        }
        .font(.caption)
    }

    /// View-mode rule name: read-only Text by default, double-click flips
    /// into the inline editor. Commit routes through `store.renameRule`
    /// so rules.yaml AND rules.log are kept in sync; collisions are
    /// rejected silently (the edit-mode form has the validated UI).
    @ViewBuilder
    private var nameField: some View {
        if editingName {
            InlineEditField(
                text: $draftName,
                placeholder: "rule-name",
                onCommit: commitNameEdit,
                onCancel: cancelNameEdit
            )
            .font(.title3)
            .fontWeight(.semibold)
            .frame(maxWidth: 360)
        } else {
            Text(sourceRule?.name ?? "")
                .font(.title3)
                .fontWeight(.semibold)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { startNameEdit() }
                .help("Double-click to rename")
        }
    }

    /// View-mode description: read-only Text by default, double-click to
    /// flip into a single-line editor. Click-off / Enter commits via
    /// `commitDescriptionEdit`; Escape reverts.
    @ViewBuilder
    private var descriptionField: some View {
        if editingDescription {
            InlineEditField(
                text: $draftDescription,
                placeholder: "What does this rule do?",
                onCommit: commitDescriptionEdit,
                onCancel: cancelDescriptionEdit
            )
        } else if let desc = sourceRule?.description, !desc.isEmpty {
            Text(taggedAttributedString(desc))
                .font(.callout)
                .foregroundStyle(.primary.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { startDescriptionEdit() }
                .help("Double-click to edit")
        } else {
            Text("(No description — double-click to add one)")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .italic()
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { startDescriptionEdit() }
        }
    }

    /// Install a local mouse-down monitor that resigns first responder on
    /// any click outside the currently-focused NSTextField. Only active
    /// while a regex condition is focused (i.e. while `regexGuideForID`
    /// is non-nil) so we don't interfere with non-regex fields' natural
    /// focus retention.
    private func installRegexClickMonitor() {
        guard regexClickMonitor == nil else { return }
        regexClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            guard let window = event.window,
                  let editor = window.firstResponder as? NSText,
                  let field = editor.delegate as? NSTextField else {
                return event
            }
            // Field's frame in window coords (`to: nil`).
            let frameInWindow = field.superview?.convert(field.frame, to: nil) ?? field.frame
            if !frameInWindow.contains(event.locationInWindow) {
                // Defer one tick so the click reaches its real target
                // (another field, a button, a row) before we resign.
                // Resigning fires controlTextDidEndEditing → onEndEditing
                // → clears regexGuideForID → this monitor uninstalls.
                DispatchQueue.main.async {
                    window.makeFirstResponder(nil)
                }
            }
            return event
        }
    }

    private func removeRegexClickMonitor() {
        if let m = regexClickMonitor {
            NSEvent.removeMonitor(m)
            regexClickMonitor = nil
        }
    }

    private func startDescriptionEdit() {
        draftDescription = sourceRule?.description ?? ""
        editingDescription = true
    }

    private func cancelDescriptionEdit() {
        editingDescription = false
        draftDescription = ""
    }

    private func commitDescriptionEdit() {
        // onEndEditing can fire after an Escape-driven exit; bail if we
        // already cleared the editing flag.
        guard editingDescription else { return }
        editingDescription = false
        let trimmed = draftDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let originalDesc = sourceRule?.description ?? ""
        guard trimmed != originalDesc else { return }
        guard let source = sourceRule else { return }
        var updated = source
        updated.description = trimmed.isEmpty ? nil : trimmed
        store.saveRule(updated)
    }

    private func startNameEdit() {
        draftName = sourceRule?.name ?? ""
        editingName = true
    }

    private func cancelNameEdit() {
        editingName = false
        draftName = ""
    }

    private func commitNameEdit() {
        // Same lifecycle gotcha as description: onEndEditing fires after
        // Escape too, so bail if we already cleared the flag.
        guard editingName else { return }
        editingName = false
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        let originalName = sourceRule?.name ?? ""
        guard !trimmed.isEmpty else { return }
        guard trimmed != originalName else { return }
        // Reject silently if the new name collides — the user will see
        // the unchanged title (revert). The rename sheet is the surface
        // that shows the validation error explicitly.
        if store.rules.contains(where: { $0.name == trimmed }) { return }
        store.renameRule(oldName: originalName, newName: trimmed)
    }

    private var viewMatchSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Match", subtitle: "All conditions must hold")
            VStack(alignment: .leading, spacing: 4) {
                ForEach(matchPairs(), id: \.0) { pair in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(pair.0)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .frame(width: 130, alignment: .trailing)
                        Text(pair.1)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                        Spacer()
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private var viewActionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Actions", subtitle: "Applied to matching items")
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array((sourceRule?.actions ?? []).enumerated()), id: \.offset) { _, action in
                    actionDetailRow(action)
                }
                if (sourceRule?.actions ?? []).isEmpty {
                    Text("(no actions)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .italic()
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    @ViewBuilder
    private func actionDetailRow(_ action: RuleAction) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let tags = action.addTags, !tags.isEmpty {
                actionLine(icon: "tag", label: "Add tags") {
                    HStack(spacing: 4) {
                        ForEach(tags, id: \.self) { tag in
                            Text("#\(tag)")
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.blue.opacity(0.15), in: Capsule())
                                .foregroundStyle(.blue)
                        }
                    }
                }
            }
            if let coll = action.addCollection, !coll.isEmpty {
                actionLine(icon: "folder", label: "Collection") {
                    Text(coll)
                        .font(.callout)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.orange.opacity(0.15), in: Capsule())
                        .foregroundStyle(.orange)
                }
            }
            if let v = action.setTitle, !v.isEmpty {
                actionLine(icon: "textformat", label: "Set title") {
                    Text(v)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
            }
            if let v = action.setNote, !v.isEmpty {
                actionLine(icon: "note.text", label: "Set note") {
                    Text(v)
                        .font(.callout)
                        .textSelection(.enabled)
                }
            }
            if let v = action.appendNote, !v.isEmpty {
                actionLine(icon: "plus.bubble", label: "Append note") {
                    Text(v)
                        .font(.callout)
                        .textSelection(.enabled)
                }
            }
            if let v = action.notify, !v.isEmpty {
                actionLine(icon: "bell", label: "Notify") {
                    Text(v)
                        .font(.callout)
                        .textSelection(.enabled)
                }
            }
            if action.skip == true {
                actionLine(icon: "exclamationmark.triangle.fill", label: "Skip") {
                    Text("Drop the item entirely")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
            if let l = action.linkTo {
                actionLine(icon: "link", label: "Link to") {
                    if let tag = l.tag, !tag.isEmpty {
                        Text("all items tagged ")
                            .font(.callout)
                          + Text("#\(tag)")
                            .font(.callout.bold())
                            .foregroundStyle(.teal)
                    } else if let id = l.id, !id.isEmpty {
                        Text("item ")
                            .font(.callout)
                          + Text(id)
                            .font(.callout.monospaced())
                            .foregroundStyle(.teal)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func actionLine<Content: View>(icon: String, label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label(label, systemImage: icon)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
                .frame(width: 130, alignment: .trailing)
            content()
            Spacer()
        }
    }

    private func sectionHeader(_ title: String, subtitle: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.semibold)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func matchPairs() -> [(String, String)] {
        let m = sourceRule?.match ?? RuleMatch()
        var out: [(String, String)] = []
        if let v = m.type, !v.isEmpty { out.append(("type", v)) }
        if let v = m.domain, !v.isEmpty { out.append(("domain", v)) }
        if let v = m.urlRegex, !v.isEmpty { out.append(("url_regex", v)) }
        if let v = m.mimeType, !v.isEmpty { out.append(("mime_type", v)) }
        if let v = m.mimeTypePrefix, !v.isEmpty { out.append(("mime_type_prefix", v)) }
        if let v = m.sender, !v.isEmpty { out.append(("sender", v)) }
        if let v = m.senderDomain, !v.isEmpty { out.append(("sender_domain", v)) }
        if let v = m.pathGlob, !v.isEmpty { out.append(("path_glob", v)) }
        if let v = m.content, !v.isEmpty { out.append(("content", v)) }
        if let v = m.contentRegex, !v.isEmpty { out.append(("content_regex", v)) }
        if out.isEmpty { out.append(("(empty)", "—")) }
        return out
    }

    // MARK: - Activity mode (per-rule)

    private var activityMode: some View {
        VStack(alignment: .leading, spacing: 0) {
            viewHeader
            activityBody
        }
    }

    @ViewBuilder
    private var activityBody: some View {
        // Filter the store's pre-fetched events to just this rule. The
        // earlier `loadRuleEvents(rule:)` call already narrowed to this
        // rule on the CLI side, but we re-filter to be defensive — the
        // store's `ruleEvents` is shared with the global activity feed
        // and could contain events for other rules if the user toggled
        // navigation quickly.
        let name = sourceRule?.name ?? ""
        let events = store.ruleEvents.filter { ev in
            ev.rules.contains(name)
        }

        if store.ruleEventsLoading && events.isEmpty {
            ProgressView("Loading activity...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if events.isEmpty {
            ContentUnavailableView {
                Label("No activity yet", systemImage: "clock.arrow.circlepath")
            } description: {
                Text("This rule hasn't fired yet. Capture something it matches and the event will appear here.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(events) { ev in
                        activityEventRow(ev)
                    }
                }
                .padding(10)
            }
        }
    }

    private func activityEventRow(_ event: RuleEvent) -> some View {
        let typeColor = RuleEventTypeBadge.color(for: event.type)
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: event.type.icon)
                .font(.title3)
                .foregroundStyle(typeColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(event.title.isEmpty ? "(untitled)" : event.title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                    Text(event.timestamp, style: .relative)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                RuleEventTypeBadge(type: event.type)
                if !event.source.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("Matched:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(event.source)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .textSelection(.enabled)
                    }
                }
                if let effects = event.effects, !effects.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(effects, id: \.self) { raw in
                            describedEffect(raw)
                        }
                    }
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func installActivityIngestObserver() {
        guard activityIngestObserver == nil else { return }
        activityIngestObserver = NotificationCenter.default.addObserver(
            forName: .stashDidIngest,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                if mode == .activity, let name = sourceRule?.name {
                    store.loadRuleEvents(rule: name)
                }
            }
        }
    }

    private func removeActivityIngestObserver() {
        if let token = activityIngestObserver {
            NotificationCenter.default.removeObserver(token)
            activityIngestObserver = nil
        }
    }

    // MARK: - Edit mode

    private var editMode: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                // Existing rules: their (immutable) name doubles as the
                // header — the Name field below would only repeat it.
                // Drafts: the editable Name field is the canonical entry
                // point; show a generic header here so the form has a
                // top anchor without duplicating the field.
                Text(isDraft ? "New Rule" : (sourceRule?.name ?? ""))
                    .font(.title3)
                    .fontWeight(.semibold)
                if hasUnsavedChanges {
                    Text("Unsaved")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.orange.opacity(0.2), in: Capsule())
                        .foregroundStyle(.orange)
                }
                Spacer()
            }
            .padding(.horizontal)
            .padding(.top, 14)
            .padding(.bottom, 8)
            .background(.bar)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // Name is editable for drafts AND existing rules.
                    // Renaming an existing rule routes through
                    // `store.renameRule` on save so rules.yaml AND
                    // rules.log are updated atomically; collisions are
                    // caught by `nameValidation` and surfaced inline.
                    VStack(alignment: .leading, spacing: 4) {
                        StashField("Name", text: $name, prompt: "e.g. youtube-videos")
                        nameValidationIndicator
                    }

                    StashField("Description (optional)", text: $ruleDescription,
                               prompt: "One line about what this rule does")

                    matchSection
                    actionsSection

                    Toggle("Enabled", isOn: $enabled)
                        .toggleStyle(.checkbox)

                    if let err = store.rulesError {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 16)
            }

            Divider()
            HStack {
                if !isDraft {
                    Button("Delete", role: .destructive) {
                        if let name = sourceRule?.name {
                            store.deleteRule(name: name)
                        }
                    }
                }
                Spacer()
                Button("Cancel") {
                    if isDraft {
                        store.discardDraft()
                    } else {
                        reloadFromSource()
                        mode = .view
                    }
                }
                .keyboardShortcut(.cancelAction)
                Button(isDraft ? "Create" : "Save") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave || (!hasUnsavedChanges && !isDraft))
            }
            .padding()
        }
    }

    private var matchSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Match", subtitle: "All conditions must hold")
            ForEach($conditions) { $condition in
                HStack {
                    Picker("", selection: $condition.key) {
                        ForEach(MatchKey.allCases) { key in
                            Text(key.label).tag(key)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 160)

                    FilterField(
                        placeholder: condition.key.placeholder,
                        text: $condition.value,
                        onBeginEditing: {
                            let id = condition.id
                            let isRegex = condition.key == .urlRegex || condition.key == .contentRegex
                            if isRegex {
                                // Defer one runloop tick — SwiftUI's
                                // popover lifecycle on macOS 15 doesn't
                                // attach reliably when the show signal
                                // is written synchronously from inside
                                // controlTextDidBeginEditing.
                                DispatchQueue.main.async {
                                    regexGuideForID = id
                                }
                            }
                        },
                        onEndEditing: {
                            if regexGuideForID == condition.id {
                                regexGuideForID = nil
                            }
                        }
                    )
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(.quaternary.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .popover(
                        isPresented: Binding(
                            get: { regexGuideForID == condition.id },
                            set: { newValue in
                                if !newValue && regexGuideForID == condition.id {
                                    regexGuideForID = nil
                                }
                            }
                        ),
                        attachmentAnchor: .rect(.bounds),
                        arrowEdge: .top
                    ) {
                        RegexGuideView()
                    }

                    Button {
                        removeCondition(condition.id)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .disabled(conditions.count == 1)
                    .foregroundStyle(conditions.count == 1 ? .tertiary : .secondary)
                }
            }
            Button {
                conditions.append(.empty)
            } label: {
                Label("Add condition", systemImage: "plus.circle")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
        }
    }

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Actions", subtitle: "Applied in order; effects compose")
            ForEach($actionRows) { $row in
                actionRowView(row: $row)
            }
            Button {
                actionRows.append(ActionRow(type: .addTags))
            } label: {
                Label("Add action", systemImage: "plus.circle")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
        }
    }

    @ViewBuilder
    private func actionRowView(row: Binding<ActionRow>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Menu {
                    ForEach(ActionType.allCases) { type in
                        Button {
                            row.wrappedValue.type = type
                        } label: {
                            Label(type.label, systemImage: type.icon)
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: row.wrappedValue.type.icon)
                        Text(row.wrappedValue.type.label)
                            .fontWeight(.medium)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Spacer()

                Button {
                    actionRows.removeAll { $0.id == row.wrappedValue.id }
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            actionRowEditor(row: row)
        }
        .padding(8)
        .background(.quaternary.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func actionRowEditor(row: Binding<ActionRow>) -> some View {
        switch row.wrappedValue.type {
        case .addTags:
            VStack(alignment: .leading, spacing: 4) {
                MultiTagField(text: row.tagsText, allTags: store.tags)
                Text("Tags add to the item; user-supplied -T tags merge in.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        case .addCollection:
            VStack(alignment: .leading, spacing: 4) {
                FilterField(placeholder: "Collection name", text: row.stringValue)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(.quaternary.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                Text("Auto-created if missing. First matching rule with a collection wins.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        case .setTitle:
            VStack(alignment: .leading, spacing: 4) {
                FilterField(placeholder: "{{.Sender}} — {{.Subject}}", text: row.stringValue)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(.quaternary.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                Text("Replaces the auto-detected title. Templates supported.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        case .setNote:
            VStack(alignment: .leading, spacing: 4) {
                StashTextEditor(text: row.stringValue)
                    .frame(height: 60)
                Text("Replaces the note field entirely. Templates supported.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        case .appendNote:
            VStack(alignment: .leading, spacing: 4) {
                StashTextEditor(text: row.stringValue)
                    .frame(height: 60)
                Text("Appended to existing notes (newline-separated). Templates supported.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        case .notify:
            VStack(alignment: .leading, spacing: 4) {
                FilterField(placeholder: "Stashed: {{.Title}}", text: row.stringValue)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(.quaternary.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                Text("Fires a macOS notification. Clickable when terminal-notifier is installed.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        case .skip:
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Drop the item entirely. It won't be saved.")
                        .font(.caption)
                    Text("Audit entries are written to ~/.stash/skip.log.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        case .linkTo:
            VStack(alignment: .leading, spacing: 6) {
                Picker("Link by", selection: row.linkMode) {
                    Text("Tag").tag(LinkMode.tag)
                    Text("Item ID").tag(LinkMode.id)
                }
                .pickerStyle(.segmented)
                if row.wrappedValue.linkMode == .tag {
                    FilterField(placeholder: "tag name", text: row.linkTag)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(.quaternary.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                    Text("Auto-link this item to all items with that tag (capped at 50).")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    FilterField(placeholder: "01ABCDEF...", text: row.linkID)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(.quaternary.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                    Text("Auto-link this item to the specified item ID.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Loading / saving

    private func reloadFromSource() {
        // Drop any in-flight inline edit when the selection changes, so the
        // new rule renders cleanly without our stale draft text.
        editingDescription = false
        draftDescription = ""
        editingName = false
        draftName = ""

        let key = store.selectedRuleName ?? ""
        loadedSource = key
        guard let rule = sourceRule else {
            name = ""
            ruleDescription = ""
            enabled = true
            conditions = [.empty]
            actionRows = []
            pristineSnapshot = ""
            mode = .view
            return
        }
        name = rule.name
        ruleDescription = rule.description ?? ""
        enabled = rule.isEnabled
        conditions = MatchCondition.from(match: rule.match)
        if conditions.isEmpty { conditions = [.empty] }
        actionRows = rule.actions?.flatMap(ActionRow.from(action:)) ?? []
        if actionRows.isEmpty { actionRows = [ActionRow(type: .addTags)] }
        pristineSnapshot = currentSnapshot()
        // Drafts always start in edit mode — no read-only state to view yet.
        mode = isDraft ? .edit : .view
    }

    private func removeCondition(_ id: UUID) {
        if conditions.count <= 1 {
            conditions = [.empty]
        } else {
            conditions.removeAll { $0.id == id }
        }
    }

    private func save() {
        let rule = buildRule()
        let originalName = isDraft ? "" : (sourceRule?.name ?? "")
        let renamed = !isDraft && rule.name != originalName

        if renamed {
            // Rename first so rules.yaml is updated under the new key
            // and rules.log is rewritten. Then save the rest of the
            // rule's fields under the new name. The store's renameRule
            // re-selects the rule under its new name, so the subsequent
            // saveRule lands on the right entry.
            store.renameRule(oldName: originalName, newName: rule.name)
        }
        store.saveRule(rule)
        // Optimistic transition back to view mode; if the save fails the
        // store surfaces the error and the rule list reload restores us.
        if !isDraft { mode = .view }
    }

    private func buildRule() -> Rule {
        var match = RuleMatch()
        for c in conditions {
            let value = c.value.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            switch c.key {
            case .type:           match.type = value
            case .domain:         match.domain = value
            case .urlRegex:       match.urlRegex = value
            case .mimeType:       match.mimeType = value
            case .mimeTypePrefix: match.mimeTypePrefix = value
            case .sender:         match.sender = value
            case .senderDomain:   match.senderDomain = value
            case .pathGlob:       match.pathGlob = value
            case .content:        match.content = value
            case .contentRegex:   match.contentRegex = value
            }
        }
        let actions = actionRows.compactMap { $0.toRuleAction() }
        let trimmedDesc = ruleDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return Rule(
            name: name.trimmingCharacters(in: .whitespaces),
            description: trimmedDesc.isEmpty ? nil : trimmedDesc,
            enabled: enabled ? nil : false,
            match: match,
            actions: actions.isEmpty ? nil : actions
        )
    }

    private func currentSnapshot() -> String {
        let cond = conditions.map { "\($0.key.rawValue):\($0.value)" }.joined(separator: "|")
        let desc = ruleDescription
        let acts = actionRows.map { row -> String in
            switch row.type {
            case .addTags:       return "tags=\(row.tagsText)"
            case .addCollection: return "coll=\(row.stringValue)"
            case .setTitle:      return "title=\(row.stringValue)"
            case .setNote:       return "note=\(row.stringValue)"
            case .appendNote:    return "append=\(row.stringValue)"
            case .notify:        return "notify=\(row.stringValue)"
            case .skip:          return "skip"
            case .linkTo:        return "link=\(row.linkMode.rawValue):\(row.linkTag):\(row.linkID)"
            }
        }.joined(separator: "|")
        return "\(name)|\(desc)|\(enabled)|\(cond)|\(acts)"
    }

    @ViewBuilder
    private func describedEffect(_ raw: String) -> some View {
        let (label, value) = RuleEffectFormatter.format(raw)
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            if !value.isEmpty {
                Text(value)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
    }
}

/// Translates compact `rules.log` effect strings (e.g. `tags:video,watch-later`)
/// into a human-readable label/value pair for display. The CLI keeps the log
/// format compact; the GUI dresses it up at render time.
enum RuleEffectFormatter {
    static func format(_ raw: String) -> (label: String, value: String) {
        if raw == "notify" {
            return ("Sent notification", "")
        }
        if raw.hasPrefix("notify×") {
            let n = raw.dropFirst("notify×".count)
            return ("Sent \(n) notifications", "")
        }
        guard let colon = raw.firstIndex(of: ":") else {
            return (raw, "")
        }
        let key = String(raw[..<colon])
        let rest = String(raw[raw.index(after: colon)...])
        switch key {
        case "tags":
            let pretty = rest.split(separator: ",").map { "#\($0)" }.joined(separator: " ")
            return ("Added tags:", pretty)
        case "coll":
            return ("Added to collection:", rest)
        case "title":
            return ("Set title:", rest)
        case "note":
            return ("Set note:", rest)
        case "note+":
            return ("Appended note:", rest)
        case "link":
            if rest.hasPrefix("#") {
                return ("Linked to tag:", rest)
            }
            return ("Linked to item:", rest)
        default:
            return (key + ":", rest)
        }
    }
}
