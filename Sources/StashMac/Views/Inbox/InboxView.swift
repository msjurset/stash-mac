import SwiftUI
import AppKit

/// Inbox: the unified triage surface combining "From your sources"
/// (feed candidates) and "From your stash" (resurface picks). Both
/// sections share the same keyboard cursor (J/K) and verbs
/// (S/X/Z/T/Enter), but the action semantics differ:
///
///   Feed candidates                   Resurface picks
///   ─────────────────────────────     ─────────────────────────
///   S    — stash + dismiss row        S    — (no-op; already stashed)
///   X    — dismiss                    X    — stop resurfacing
///   Z    — snooze 1d                  Z    — snooze 7d
///   T    — tag picker (TBD)           T    — tag picker (TBD)
///   Enter/O — open in browser         Enter/O — open in default handler
///   Space — preview popover           Space — preview popover
///
/// Phase 2 ships the wiring + happy-path triage. T (tag picker on the
/// fly) and a richer preview are Phase 3.
struct InboxView: View {
    @Environment(StashStore.self) private var store

    /// Which row is highlighted across both sections. Sections are
    /// `feed` and `resurface`; index is the row inside that section.
    @State private var selection: Selection = .none
    /// Multi-select set extended via Shift-J / Shift-K. The cursor
    /// `selection` is always the anchor; `extendedSelection` is the
    /// inclusive range from the original anchor down/up to wherever
    /// the user has Shift-arrowed. Empty means single-row selection
    /// (just `selection` itself).
    @State private var extendedSelection: Set<Selection> = []
    /// Shows the snooze duration picker anchored on the active row.
    /// Set by Shift-Z or the row's context menu; tapping a duration
    /// applies it to whichever rows are in the selection set.
    @State private var snoozePickerOpen = false
    @State private var showAddFeedSheet = false
    @State private var showManageFeedsSheet = false

    enum Selection: Hashable {
        case none
        case queue(String)     // item ID
        case feed(Int64)       // candidate ID
        case resurface(String) // item ID
    }

    /// One option in the snooze picker. Durations chosen to cover the
    /// 80% of "not now, ask later" requests: 1h is for an active
    /// task user-context, the rest are calendar-shaped.
    enum SnoozeChoice: String, CaseIterable, Identifiable {
        case oneHour      = "1 hour"
        case sixHours     = "6 hours"
        case oneDay       = "1 day"
        case threeDays    = "3 days"
        case oneWeek      = "1 week"

        var id: String { rawValue }
        var goDuration: String {
            switch self {
            case .oneHour:   return "1h"
            case .sixHours:  return "6h"
            case .oneDay:    return "24h"
            case .threeDays: return "72h"
            case .oneWeek:   return "168h"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        queueSection
                        sourcesSection
                        resurfaceSection
                    }
                    .padding(.vertical, 6)
                }
                .onChange(of: selection) { _, new in
                    if let anchor = scrollAnchor(for: new) {
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(anchor, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(KeyMonitor(onKey: handleKey))
        .toolbar {
            ToolbarItem {
                ContextualHelpButton(topic: .gettingStarted, isToolbarItem: true)
            }
        }
        .onAppear {
            store.loadInbox()
            if selection == .none {
                selection = initialSelection()
            }
            syncDetail()
        }
        .onChange(of: selection) { _, _ in syncDetail() }
        .onChange(of: store.feedCandidates) { _, _ in
            // Items list may have shifted indices after triage; re-anchor.
            if selection == .none { selection = initialSelection() }
            syncDetail()
        }
        .onChange(of: store.queueItems) { _, _ in
            if selection == .none { selection = initialSelection() }
            syncDetail()
        }
        .onChange(of: store.resurfaceItems) { _, _ in
            if selection == .none { selection = initialSelection() }
            syncDetail()
        }
    }

    /// Push the currently highlighted row into the store so the
    /// `InboxDetailView` in the third NavigationSplitView column can
    /// render a preview. Only one of the two store slots is set at a
    /// time; the other is cleared.
    private func syncDetail() {
        switch selection {
        case .queue(let id):
            store.inboxSelectedCandidate = nil
            store.inboxSelectedResurfaceItem = store.queueItems.first(where: { $0.id == id })
        case .feed(let id):
            store.inboxSelectedCandidate = store.feedCandidates.first(where: { $0.id == id })
            store.inboxSelectedResurfaceItem = nil
        case .resurface(let id):
            store.inboxSelectedCandidate = nil
            store.inboxSelectedResurfaceItem = store.resurfaceItems.first(where: { $0.id == id })
        default:
            store.inboxSelectedCandidate = nil
            store.inboxSelectedResurfaceItem = nil
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Inbox").font(.title2).bold()
                Text(headerSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                showAddFeedSheet = true
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .focusable(false)
            .help("Add a feed")
            Button {
                showManageFeedsSheet = true
            } label: {
                Image(systemName: "antenna.radiowaves.left.and.right")
            }
            .buttonStyle(.borderless)
            .focusable(false)
            .help("Manage feeds")
            Button {
                store.pollFeeds()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .focusable(false)
            .help("Poll feeds now")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .sheet(isPresented: $showAddFeedSheet) {
            AddFeedSheet()
        }
        .sheet(isPresented: $showManageFeedsSheet) {
            ManageFeedsSheet()
        }
    }

    private var headerSubtitle: String {
        let queue = store.queueItems.count
        let unread = store.feedCandidates.count
        let resurface = store.resurfaceItems.count
        var parts: [String] = []
        if queue > 0 { parts.append("\(queue) to read/watch") }
        if unread > 0 { parts.append("\(unread) unread") }
        if resurface > 0 { parts.append("\(resurface) to revisit") }
        if parts.isEmpty { parts.append("Nothing to triage right now") }
        if let last = store.lastFeedPoll {
            let mins = Int(Date().timeIntervalSince(last) / 60)
            parts.append("polled \(mins)m ago")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Sections

    @ViewBuilder
    private var queueSection: some View {
        if !store.queueItems.isEmpty {
            sectionHeader(
                "To read & watch",
                count: store.queueItems.count,
                hint: "S mark done · X stop showing · Z snooze (⇧Z picker) · Enter open",
                trailing: AnyView(
                    Button {
                        store.showReadWatchList()
                    } label: {
                        Image(systemName: "list.bullet.rectangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Show all read/watch items in the list view")
                )
            )
            ForEach(store.queueItems) { item in
                queueRow(item)
                    .id(Selection.queue(item.id))
            }
        }
    }

    @ViewBuilder
    private var sourcesSection: some View {
        if !store.feedCandidates.isEmpty {
            sectionHeader(
                "From your sources",
                count: store.feedCandidates.count,
                hint: "S stash · X dismiss · Z snooze (⇧Z picker) · Enter open · ⇧J/⇧K extend"
            )
            ForEach(store.feedCandidates) { cand in
                feedRow(cand)
                    .id(Selection.feed(cand.id))
            }
        }
    }

    @ViewBuilder
    private var resurfaceSection: some View {
        if !store.resurfaceItems.isEmpty {
            sectionHeader(
                "From your stash",
                count: store.resurfaceItems.count,
                hint: "X stop resurfacing · Z snooze (⇧Z picker) · Enter open · ⇧J/⇧K extend"
            )
            ForEach(store.resurfaceItems) { item in
                resurfaceRow(item)
                    .id(Selection.resurface(item.id))
            }
        }
    }

    /// Section header in two rows: title + count + optional trailing
    /// action on the first row; muted hint on its own line below so
    /// it has room to wrap without crowding the title.
    private func sectionHeader(
        _ title: String,
        count: Int,
        hint: String,
        trailing: AnyView? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(title).font(.headline)
                Text("\(count)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                if let trailing { trailing }
            }
            Text(hint)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    // MARK: - Row renderers

    @ViewBuilder
    private func feedRow(_ c: FeedCandidate) -> some View {
        let sel = Selection.feed(c.id)
        let cursor = (selection == sel)
        let extended = extendedSelection.contains(sel)
        let active = cursor || extended
        HStack(alignment: .top, spacing: 10) {
            thumb(url: c.thumbnailUrl)
            VStack(alignment: .leading, spacing: 2) {
                Text(c.displayTitle)
                    .font(.body)
                    .lineLimit(2)
                    .foregroundStyle(active ? .white : .primary)
                HStack(spacing: 6) {
                    if let s = c.sourceName {
                        Text(s).font(.caption).foregroundStyle(active ? Color.white.opacity(0.85) : .secondary)
                    }
                    Text("·").foregroundStyle(active ? Color.white.opacity(0.6) : Color.secondary.opacity(0.5)).font(.caption)
                    Text(c.displayWhen, style: .relative)
                        .font(.caption)
                        .foregroundStyle(active ? Color.white.opacity(0.85) : .secondary)
                }
                if let excerpt = rowExcerpt(c), !excerpt.isEmpty {
                    Text(excerpt)
                        .font(.caption)
                        .foregroundStyle(active ? Color.white.opacity(0.85) : .secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(active ? Color.accentColor.opacity(cursor ? 1.0 : 0.55) : Color.clear)
        .contentShape(Rectangle())
        .pointingHandCursor()
        .onTapGesture {
            selection = .feed(c.id)
            extendedSelection = []
        }
        .overlay(alignment: .trailing) {
            if cursor && snoozePickerOpen {
                snoozePickerMenu
                    .padding(.trailing, 14)
            }
        }
        .contextMenu {
            Button("Stash") { store.stashCandidate(c) }
            Button("Open in Browser") { openURL(c.url) }
            Divider()
            snoozeMenuButtons {
                store.snoozeCandidate(c, duration: $0.goDuration)
            }
            Button("Dismiss", role: .destructive) { store.dismissCandidate(c) }
        }
    }

    @ViewBuilder
    private func queueRow(_ item: StashItem) -> some View {
        let sel = Selection.queue(item.id)
        let cursor = (selection == sel)
        let extended = extendedSelection.contains(sel)
        let active = cursor || extended
        let queueTag = queueTagFor(item)
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: queueTag == "watch-later" ? "play.rectangle" : "book")
                .frame(width: 44, height: 44)
                .foregroundStyle(active ? .white : .accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.body)
                    .lineLimit(2)
                    .foregroundStyle(active ? .white : .primary)
                
                HStack(spacing: 6) {
                    Text("added")
                        .font(.caption)
                        .foregroundStyle(active ? Color.white.opacity(0.85) : Color.secondary.opacity(0.7))
                    Text(item.createdAt, style: .relative)
                        .font(.caption)
                        .foregroundStyle(active ? Color.white.opacity(0.85) : .secondary)
                }

                HStack(spacing: 6) {
                    if let queueTag {
                        Text("#\(queueTag)")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background((active ? Color.white.opacity(0.25) : Color.accentColor.opacity(0.18)),
                                        in: Capsule())
                            .foregroundStyle(active ? .white : .accentColor)
                    }
                    
                    let otherTags = (item.tags ?? [])
                        .map(\.name)
                        .filter { $0 != "read-later" && $0 != "watch-later" }
                    if !otherTags.isEmpty {
                        Text(otherTags.map { "#\($0)" }.joined(separator: " "))
                            .font(.caption)
                            .foregroundStyle(active ? Color.white.opacity(0.85) : Color.secondary.opacity(0.5))
                            .lineLimit(1)
                    }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(active ? Color.accentColor.opacity(cursor ? 1.0 : 0.55) : Color.clear)
        .contentShape(Rectangle())
        .pointingHandCursor()
        .onTapGesture {
            selection = .queue(item.id)
            extendedSelection = []
        }
        .overlay(alignment: .trailing) {
            if cursor && snoozePickerOpen {
                snoozePickerMenu
                    .padding(.trailing, 14)
            }
        }
        .contextMenu {
            Button("Open") { store.openItem(id: item.id) }
            Button("Mark done") { store.markQueueItemDone(item) }
            Button("Reveal in List") {
                store.selectItemByID(item.id, revealInList: true)
            }
            Divider()
            snoozeMenuButtons {
                store.snoozeResurface(item, duration: $0.goDuration)
            }
            Button("Stop showing in inbox", role: .destructive) {
                store.dismissResurface(item)
            }
        }
    }

    /// First queue tag found on the item — typically just one but
    /// shown distinctly per row when both are present.
    private func queueTagFor(_ item: StashItem) -> String? {
        let names = (item.tags ?? []).map(\.name)
        if names.contains("read-later") { return "read-later" }
        if names.contains("watch-later") { return "watch-later" }
        return nil
    }

    @ViewBuilder
    private func resurfaceRow(_ item: StashItem) -> some View {
        let sel = Selection.resurface(item.id)
        let cursor = (selection == sel)
        let extended = extendedSelection.contains(sel)
        let active = cursor || extended
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.type.icon)
                .frame(width: 44, height: 44)
                .foregroundStyle(active ? .white : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.body)
                    .lineLimit(2)
                    .foregroundStyle(active ? .white : .primary)
                HStack(spacing: 6) {
                    Text("not seen since")
                        .font(.caption)
                        .foregroundStyle(active ? Color.white.opacity(0.85) : Color.secondary.opacity(0.5))
                    Text(item.updatedAt, style: .date)
                        .font(.caption)
                        .foregroundStyle(active ? Color.white.opacity(0.85) : .secondary)
                }
                if let tags = item.tags, !tags.isEmpty {
                    Text(tags.map { "#\($0.name)" }.joined(separator: " "))
                        .font(.caption)
                        .foregroundStyle(active ? Color.white.opacity(0.85) : Color.secondary.opacity(0.5))
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(active ? Color.accentColor.opacity(cursor ? 1.0 : 0.55) : Color.clear)
        .contentShape(Rectangle())
        .pointingHandCursor()
        .onTapGesture {
            selection = .resurface(item.id)
            extendedSelection = []
        }
        .overlay(alignment: .trailing) {
            if cursor && snoozePickerOpen {
                snoozePickerMenu
                    .padding(.trailing, 14)
            }
        }
        .contextMenu {
            Button("Open") { store.openItem(id: item.id) }
            Button("Reveal in List") {
                store.selectItemByID(item.id, revealInList: true)
            }
            Divider()
            snoozeMenuButtons {
                store.snoozeResurface(item, duration: $0.goDuration)
            }
            Button("Stop resurfacing", role: .destructive) { store.dismissResurface(item) }
        }
    }

    /// Five context-menu buttons covering the canonical snooze
    /// durations. Factored out because both row types share them.
    @ViewBuilder
    private func snoozeMenuButtons(_ apply: @escaping (SnoozeChoice) -> Void) -> some View {
        ForEach(SnoozeChoice.allCases) { choice in
            Button("Snooze \(choice.rawValue)") { apply(choice) }
        }
    }

    /// The floating duration picker overlaid on the active row when
    /// Shift-Z fires. Tapping a choice runs the same `applyToTargets`
    /// flow the keyboard verbs use, so multi-select snoozes work.
    private var snoozePickerMenu: some View {
        HStack(spacing: 6) {
            ForEach(SnoozeChoice.allCases) { choice in
                Button {
                    applySnooze(choice)
                } label: {
                    Text(choice.rawValue)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.thinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Snooze \(choice.rawValue)")
            }
        }
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 6)
    }

    private func applySnooze(_ choice: SnoozeChoice) {
        snoozePickerOpen = false
        applyToTargets { sel in
            switch sel {
            case .queue(let id):
                if let item = store.queueItems.first(where: { $0.id == id }) {
                    store.snoozeResurface(item, duration: choice.goDuration)
                }
            case .feed(let id):
                if let cand = store.feedCandidates.first(where: { $0.id == id }) {
                    store.snoozeCandidate(cand, duration: choice.goDuration)
                }
            case .resurface(let id):
                if let item = store.resurfaceItems.first(where: { $0.id == id }) {
                    store.snoozeResurface(item, duration: choice.goDuration)
                }
            default: break
            }
        }
    }

    @ViewBuilder
    private func thumb(url: String?) -> some View {
        if let url, let nsURL = URL(string: url) {
            AsyncImage(url: nsURL) { phase in
                switch phase {
                case .empty:    Color.gray.opacity(0.15)
                case .success(let img): img.resizable().scaledToFill()
                case .failure:  placeholderThumb
                @unknown default: placeholderThumb
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            placeholderThumb
                .frame(width: 44, height: 44)
        }
    }

    private var placeholderThumb: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.secondary.opacity(0.15))
            .overlay(Image(systemName: "doc.text").foregroundStyle(.tertiary))
    }

    // MARK: - Keyboard handling

    private func handleKey(_ event: NSEvent) -> Bool {
        let shift = event.modifierFlags.contains(.shift)
        let chars = event.charactersIgnoringModifiers ?? ""
        // We want the un-shifted character but Shift-S still sends "S".
        // Lowercase for switch consistency.
        let key = chars.lowercased()
        switch key {
        case "j":
            if shift { extendSelection(.down) } else { move(.down); extendedSelection = [] }
            return true
        case "k":
            if shift { extendSelection(.up) } else { move(.up); extendedSelection = [] }
            return true
        case "s":
            // For queue rows, S means "mark done" (remove the
            // read-later / watch-later tag); for feed rows it means
            // stash; for resurface rows it's a no-op (already stashed).
            applyToTargets { sel in
                switch sel {
                case .queue(let id):
                    if let item = store.queueItems.first(where: { $0.id == id }) {
                        store.markQueueItemDone(item)
                    }
                case .feed(let id):
                    if let cand = store.feedCandidates.first(where: { $0.id == id }) {
                        store.stashCandidate(cand)
                    }
                default: break
                }
            }
            return true
        case "x":
            applyToTargets { sel in
                switch sel {
                case .queue(let id):
                    if let item = store.queueItems.first(where: { $0.id == id }) {
                        store.dismissResurface(item)
                    }
                case .feed(let id):
                    if let cand = store.feedCandidates.first(where: { $0.id == id }) {
                        store.dismissCandidate(cand)
                    }
                case .resurface(let id):
                    if let item = store.resurfaceItems.first(where: { $0.id == id }) {
                        store.dismissResurface(item)
                    }
                default: break
                }
            }
            return true
        case "z":
            if shift {
                snoozePickerOpen = true
                return true
            }
            // Plain Z uses the section's default snooze duration.
            applyToTargets { sel in
                switch sel {
                case .queue(let id):
                    if let item = store.queueItems.first(where: { $0.id == id }) {
                        store.snoozeResurface(item, duration: "72h")
                    }
                case .feed(let id):
                    if let cand = store.feedCandidates.first(where: { $0.id == id }) {
                        store.snoozeCandidate(cand, duration: "24h")
                    }
                case .resurface(let id):
                    if let item = store.resurfaceItems.first(where: { $0.id == id }) {
                        store.snoozeResurface(item, duration: "168h")
                    }
                default: break
                }
            }
            return true
        case "o":
            openCurrent(); return true
        case "\r":
            openCurrent(); return true
        case " ":
            openCurrent(); return true
        case "\u{1b}":
            // Escape clears multi-select extension and dismisses the
            // snooze picker if open. Falls through to the global ESC
            // path only if neither was active.
            if snoozePickerOpen {
                snoozePickerOpen = false
                return true
            }
            if !extendedSelection.isEmpty {
                extendedSelection = []
                return true
            }
            return false
        default:
            return false
        }
    }

    /// Targets for a triage verb: the multi-select set when non-empty,
    /// otherwise just the single selection. Iteration order is
    /// orderedSelections() filtered to the target set so feed-section
    /// rows act before resurface-section rows.
    private func applyToTargets(_ apply: (Selection) -> Void) {
        let targets: [Selection]
        if extendedSelection.isEmpty {
            targets = [selection]
            advanceSelection()
        } else {
            targets = orderedSelections().filter { extendedSelection.contains($0) }
            if let last = targets.last {
                selection = last
                advanceSelection()
            }
        }
        for t in targets { apply(t) }
        extendedSelection = []
    }

    /// Walk the cursor one step and extend the multi-select set to
    /// include the new cursor. Anchor (the original `selection` row
    /// before any Shift-arrow) implicitly stays in the set since the
    /// extension includes the swept-over rows.
    private func extendSelection(_ dir: Dir) {
        if extendedSelection.isEmpty {
            extendedSelection.insert(selection)
        }
        move(dir)
        extendedSelection.insert(selection)
    }

    private enum Dir { case up, down }

    private func move(_ dir: Dir) {
        let order = orderedSelections()
        guard !order.isEmpty else { return }
        let i = order.firstIndex(of: selection) ?? -1
        let next: Int
        switch dir {
        case .down: next = min(i + 1, order.count - 1)
        case .up:   next = max(i - 1, 0)
        }
        selection = order[max(next, 0)]
    }

    private func advanceSelection() {
        let order = orderedSelections()
        guard let i = order.firstIndex(of: selection) else { return }
        if i + 1 < order.count {
            selection = order[i + 1]
        } else if i > 0 {
            selection = order[i - 1]
        } else {
            selection = .none
        }
    }

    /// Flatten all three sections into one ordered list so J/K walks
    /// across them naturally. Order matches the visual section order:
    /// queue → feed candidates → resurface picks.
    private func orderedSelections() -> [Selection] {
        var out: [Selection] = []
        for item in store.queueItems     { out.append(.queue(item.id)) }
        for cand in store.feedCandidates { out.append(.feed(cand.id)) }
        for item in store.resurfaceItems { out.append(.resurface(item.id)) }
        return out
    }

    private func initialSelection() -> Selection {
        if let item = store.queueItems.first       { return .queue(item.id) }
        if let cand = store.feedCandidates.first   { return .feed(cand.id) }
        if let item = store.resurfaceItems.first   { return .resurface(item.id) }
        return .none
    }

    private func openCurrent() {
        switch selection {
        case .queue(let id):
            if let item = store.queueItems.first(where: { $0.id == id }) {
                store.openItem(id: item.id)
            }
        case .feed(let id):
            if let cand = store.feedCandidates.first(where: { $0.id == id }) {
                openURL(cand.url)
            }
        case .resurface(let id):
            if let item = store.resurfaceItems.first(where: { $0.id == id }) {
                store.openItem(id: item.id)
            }
        default: break
        }
    }

    private func openURL(_ s: String) {
        guard let url = URL(string: s) else { return }
        NSWorkspace.shared.open(url)
    }

    private func scrollAnchor(for sel: Selection) -> Selection? {
        switch sel {
        case .none: return nil
        default: return sel
        }
    }

    /// Two-line excerpt for the row. Prefers the cached Markdown
    /// from poll time (already cleaned of HTML), then falls back to
    /// the raw description run through `plainText`. The `lineLimit(2)`
    /// truncation in the row clips this to fit.
    private func rowExcerpt(_ c: FeedCandidate) -> String? {
        if let md = c.descriptionMarkdown, !md.isEmpty {
            // Collapse the multi-paragraph Markdown to a single line
            // so the row preview doesn't waste vertical space on
            // blank-line separators.
            let collapsed = md.replacingOccurrences(of: "\n\n", with: " · ")
                .replacingOccurrences(of: "\n", with: " ")
            return collapsed
        }
        if let desc = c.description, !desc.isEmpty {
            return plainText(desc)
        }
        return nil
    }

    /// Strip RSS-typical HTML to plain text for the row description.
    /// Crude, but ample for two-line excerpts; full HTML rendering is
    /// reserved for the preview popover in Phase 3.
    private func plainText(_ html: String) -> String {
        guard let data = html.data(using: .utf8) else { return html }
        let opts: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        if let attr = try? NSAttributedString(data: data, options: opts, documentAttributes: nil) {
            return attr.string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return html
    }
}

// MARK: - Key monitor

/// Sits invisibly behind the Inbox to capture J/K/S/X/Z/etc. without
/// stealing focus from text inputs elsewhere. Tied to view lifetime so
/// other views don't accidentally receive these events.
private struct KeyMonitor: NSViewRepresentable {
    let onKey: (NSEvent) -> Bool

    func makeNSView(context: Context) -> KeyCatcher {
        let v = KeyCatcher()
        v.onKey = onKey
        return v
    }

    func updateNSView(_ nsView: KeyCatcher, context: Context) {
        nsView.onKey = onKey
    }

    final class KeyCatcher: NSView {
        var onKey: ((NSEvent) -> Bool)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                installMonitor()
            } else {
                removeMonitor()
            }
        }

        private func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let win = self.window, event.window === win else { return event }
                if NSApp.keyWindow !== win { return event }
                // Don't eat keys while a text field has focus.
                if let r = win.firstResponder as? NSText, r.delegate is NSTextField { return event }
                if win.firstResponder is NSTextField { return event }
                if let handled = self.onKey?(event), handled { return nil }
                return event
            }
        }

        private func removeMonitor() {
            if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        }
    }
}
