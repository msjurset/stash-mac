import SwiftUI
import AppKit

/// Right-column detail for the currently-selected rule activity event.
/// Shows the full timestamp, source URL/path (selectable + copyable),
/// every effect (not truncated like the row), every rule that fired,
/// and — for fire/retro events — a button to jump to the item in the
/// main library.
struct RuleActivityDetailView: View {
    @Environment(StashStore.self) private var store

    private var event: RuleEvent? {
        guard let id = store.selectedRuleEventID else { return nil }
        return store.ruleEvents.first(where: { $0.id == id })
    }

    var body: some View {
        Group {
            if let event {
                detail(event)
            } else {
                ContentUnavailableView {
                    Label("Select an Event", systemImage: "clock.arrow.circlepath")
                } description: {
                    Text("Pick a row from the activity feed to see its full detail.")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func detail(_ event: RuleEvent) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(event)
                rulesSection(event)
                effectsSection(event)
                sourceSection(event)
                if let id = event.itemId, !id.isEmpty {
                    itemSection(itemID: id)
                }
            }
            .padding()
        }
    }

    private func header(_ event: RuleEvent) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: event.type.icon)
                .font(.system(size: 28))
                .foregroundStyle(typeColor(for: event.type))
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text(event.title.isEmpty ? "(untitled)" : event.title)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .textSelection(.enabled)
                HStack(spacing: 8) {
                    Text(event.type.label.uppercased())
                        .font(.caption.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(typeColor(for: event.type).opacity(0.18), in: Capsule())
                        .foregroundStyle(typeColor(for: event.type))
                    Text(event.timestamp, format: .dateTime.year().month().day().hour().minute().second())
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Spacer()
        }
    }

    private func rulesSection(_ event: RuleEvent) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader(
                "Rule\(event.rules.count == 1 ? "" : "s")",
                subtitle: event.rules.count == 1 ? nil : "All rules that fired on this event"
            )
            FlowLayout(spacing: 6) {
                ForEach(event.rules, id: \.self) { name in
                    Button {
                        // Jump to the rule in the Rules nav so the user
                        // can inspect / edit it.
                        store.navigation = .rules
                        store.selectedRuleName = name
                    } label: {
                        Text(name)
                            .font(.callout.monospaced())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.quaternary.opacity(0.6), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Open rule \(name)")
                }
            }
        }
    }

    @ViewBuilder
    private func effectsSection(_ event: RuleEvent) -> some View {
        let effects = event.effects ?? []
        if !effects.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                sectionHeader("Effects", subtitle: nil)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(effects, id: \.self) { e in
                        Text(e)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        } else if event.type == .skip {
            VStack(alignment: .leading, spacing: 6) {
                sectionHeader("Effects", subtitle: nil)
                Text("Item was skipped — never saved.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.red.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private func sourceSection(_ event: RuleEvent) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Source", subtitle: nil)
            HStack {
                Text(event.source)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(3)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(event.source, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .help("Copy source")

                if isURL(event.source) {
                    Button {
                        if let url = URL(string: event.source) {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                    }
                    .buttonStyle(.plain)
                    .help("Open in browser")
                }
            }
            .padding(10)
            .background(.quaternary.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func itemSection(itemID: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Item", subtitle: nil)
            HStack {
                Text(itemID)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Spacer()
                Button("Open in Library") {
                    store.navigation = .allItems
                    store.selectedItemID = itemID
                }
                .help("Switch to All Items and select this row")
            }
            .padding(10)
            .background(.quaternary.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func sectionHeader(_ title: String, subtitle: String?) -> some View {
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

    private func typeColor(for type: RuleEvent.EventType) -> Color {
        switch type {
        case .fire:  return .green
        case .skip:  return .red
        case .retro: return .blue
        }
    }

    private func isURL(_ s: String) -> Bool {
        s.lowercased().hasPrefix("http://") || s.lowercased().hasPrefix("https://")
    }
}
