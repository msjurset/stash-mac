import SwiftUI

/// Activity — chronological timeline of the events that brought the
/// current item to its present state. Sources merged server-side by
/// `stash provenance <id> --json`: initial capture (synthesized from
/// the item record), any matching capture.log entries (rule fires,
/// retros, skips, errors), and matching tags.log entries (manual tag
/// add/remove via edit or bulk surfaces).
///
/// Re-loads on item-id change. Hidden entirely when there are no
/// events (legacy items with no capture.log entry will at least show
/// the synthesized "Captured" row, so this is rare in practice).
struct ProvenanceSection: View {
    let itemID: String

    @State private var events: [ProvenanceEvent] = []
    @State private var loading = true
    @State private var loadError: String?

    var body: some View {
        DetailSection(title: "Activity") {
            if loading {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let loadError {
                Text(loadError)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if events.isEmpty {
                Text("No history recorded for this item yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(events) { ev in
                        row(ev)
                    }
                }
            }
        }
        .task(id: itemID) {
            await reload()
        }
    }

    @ViewBuilder
    private func row(_ ev: ProvenanceEvent) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: ev.icon)
                .frame(width: 18)
                .foregroundStyle(color(for: ev))
            VStack(alignment: .leading, spacing: 1) {
                Text(ev.summary)
                    .font(.callout)
                    .textSelection(.enabled)
                Text(ev.timestamp, format: .dateTime
                    .year().month(.abbreviated).day()
                    .hour().minute())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Subtle color tint per event kind so the eye can scan a long
    /// timeline. Errors red; tag mutations accent; everything else
    /// the secondary muted color so the section doesn't shout.
    private func color(for ev: ProvenanceEvent) -> Color {
        switch ev.kind {
        case "error": return .red
        case "tag":   return .accentColor
        case "skip":  return .orange
        default:      return .secondary
        }
    }

    private func reload() async {
        loading = true
        loadError = nil
        do {
            events = try await StashCLI.shared.itemProvenance(id: itemID)
        } catch {
            loadError = error.localizedDescription
        }
        loading = false
    }
}
