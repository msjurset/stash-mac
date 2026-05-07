import SwiftUI

/// Middle-column read-only feed of rule activity. Filterable by type
/// (fire/skip/retro), rule name, and free-text. Selecting a row drives
/// `RuleActivityDetailView` in the detail column.
///
/// Auto-refresh: listens for `.stashDidIngest` notifications (posted by
/// every capture path on success) and reloads. So if you drop a file in
/// `Stash-Inbox` while watching this view, the new fire row appears
/// without manual refresh.
struct RuleActivityView: View {
    @Environment(StashStore.self) private var store

    @State private var filterText: String = ""
    @State private var typeFilter: RuleEvent.EventType?
    @State private var ruleFilter: String = ""
    @State private var ingestObserver: NSObjectProtocol?

    private var filteredEvents: [RuleEvent] {
        let needle = filterText.trimmingCharacters(in: .whitespaces).lowercased()
        return store.ruleEvents.filter { ev in
            if let typeFilter, ev.type != typeFilter { return false }
            if !ruleFilter.isEmpty {
                if !ev.rules.contains(where: { $0.lowercased() == ruleFilter.lowercased() }) {
                    return false
                }
            }
            if needle.isEmpty { return true }
            if ev.title.lowercased().contains(needle) { return true }
            if ev.source.lowercased().contains(needle) { return true }
            if ev.rules.contains(where: { $0.lowercased().contains(needle) }) { return true }
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
        .navigationTitle("Rule Activity")
        .toolbar {
            ToolbarItem {
                Button {
                    store.loadRuleEvents()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Reload activity from ~/.stash/rules.log")
                .disabled(store.ruleEventsLoading)
            }
        }
        .task {
            store.loadRuleEvents()
            // Auto-refresh whenever the engine reports a capture.
            ingestObserver = NotificationCenter.default.addObserver(
                forName: .stashDidIngest,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in store.loadRuleEvents() }
            }
        }
        .onDisappear {
            if let token = ingestObserver {
                NotificationCenter.default.removeObserver(token)
                ingestObserver = nil
            }
        }
    }

    private var filterBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                FilterField(placeholder: "Search title, source, rule…", text: $filterText)
                if !filterText.isEmpty {
                    Button {
                        filterText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                }
            }
            HStack(spacing: 8) {
                Picker("", selection: $typeFilter) {
                    Text("All types").tag(RuleEvent.EventType?.none)
                    Text("Fire").tag(RuleEvent.EventType?.some(.fire))
                    Text("Skip").tag(RuleEvent.EventType?.some(.skip))
                    Text("Retro").tag(RuleEvent.EventType?.some(.retro))
                    Text("Capture").tag(RuleEvent.EventType?.some(.capture))
                    Text("Error").tag(RuleEvent.EventType?.some(.error))
                }
                .labelsHidden()
                .frame(width: 130)

                FilterField(placeholder: "Rule name…", text: $ruleFilter)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(.quaternary.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                if !ruleFilter.isEmpty {
                    Button {
                        ruleFilter = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Text("\(filteredEvents.count) of \(store.ruleEvents.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if store.ruleEventsLoading && store.ruleEvents.isEmpty {
            ProgressView("Loading activity...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let err = store.ruleEventsError, store.ruleEvents.isEmpty {
            ContentUnavailableView {
                Label("Couldn't load activity", systemImage: "exclamationmark.triangle")
            } description: {
                Text(err)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.ruleEvents.isEmpty {
            ContentUnavailableView {
                Label("No rule activity yet", systemImage: "clock.arrow.circlepath")
            } description: {
                Text("Rules log fires here as they happen. Capture an item that matches a rule (e.g. drop a YouTube URL into Stash) and watch the feed update live.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filteredEvents.isEmpty {
            ContentUnavailableView(
                "No matches",
                systemImage: "line.3.horizontal.decrease.circle",
                description: Text("No events match the current filters.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            list
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(filteredEvents) { ev in
                    EventRow(
                        event: ev,
                        isSelected: store.selectedRuleEventID == ev.id
                    )
                    .onTapGesture {
                        store.selectedRuleEventID = ev.id
                    }
                }
            }
            .padding(10)
        }
    }
}

private struct EventRow: View {
    let event: RuleEvent
    let isSelected: Bool

    private var typeColor: Color {
        RuleEventTypeBadge.color(for: event.type)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
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
                HStack(spacing: 4) {
                    RuleEventTypeBadge(type: event.type)
                    ForEach(event.rules, id: \.self) { rule in
                        Text(rule)
                            .font(.caption.monospaced())
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary.opacity(0.6), in: Capsule())
                    }
                }
                if !event.source.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("Matched:")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(event.source)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                if let effects = event.effects, !effects.isEmpty {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(effects, id: \.self) { raw in
                            let parts = RuleEffectFormatter.format(raw)
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text(parts.label)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                if !parts.value.isEmpty {
                                    Text(parts.value)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.18)) : AnyShapeStyle(.quaternary.opacity(0.4)))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
    }
}
