import SwiftUI

struct HelpView: View {
    @Environment(HelpOverlayModel.self) private var helpModel
    @Environment(\.dismiss) private var dismiss
    
    /// Initial topic to land on when the window opens. Defaults to
    /// Getting Started so the menu-item path (no context) lands on
    /// a sensible introduction; the contextual `?` keyboard shortcut
    /// passes the topic that matches the current sidebar nav.
    var initialTopic: HelpTopic = .gettingStarted
    @State private var selectedTopic: HelpTopic? = nil

    var body: some View {
        HSplitView {
            // Sidebar
            List(HelpTopic.allCases, selection: $selectedTopic) { topic in
                HStack(spacing: 8) {
                    Image(systemName: topic.icon)
                        .frame(width: 20)
                        .foregroundStyle(.secondary)
                    Text(topic.rawValue)
                }
                .tag(topic)
                .padding(.vertical, 2)
            }
            .listStyle(.sidebar)
            .frame(minWidth: 180, idealWidth: 200, maxWidth: 250)

            // Detail
            if let topic = selectedTopic {
                HelpDetailView(topic: topic)
            } else {
                ContentUnavailableView(
                    "Select a Topic",
                    systemImage: "questionmark.circle",
                    description: Text("Choose a help topic from the sidebar.")
                )
            }
        }
        .frame(minWidth: 700, minHeight: 500)
        .onAppear {
            // Apply the requested initial topic on first render.
            // Subsequent opens of the same window with a different
            // value also re-apply via .onChange below.
            if selectedTopic == nil {
                selectedTopic = initialTopic
            }
        }
        .onChange(of: initialTopic) { _, new in
            selectedTopic = new
        }
    }
}

struct HelpDetailView: View {
    let topic: HelpTopic

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(topic.rawValue)
                    .font(.largeTitle)
                    .fontWeight(.bold)

                ForEach(Array(topic.sections.enumerated()), id: \.offset) { _, section in
                    renderSection(section)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func renderSection(_ section: HelpSection) -> some View {
        switch section {
        case .heading(let text):
            Text(text)
                .font(.title2)
                .fontWeight(.semibold)
                .padding(.top, 8)

        case .subheading(let text):
            Text(text)
                .font(.title3)
                .fontWeight(.medium)
                .padding(.top, 4)

        case .paragraph(let text):
            Text(text)
                .font(.body)
                .lineSpacing(4)

        case .bullet(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(items, id: \.self) { text in
                    HStack(alignment: .top, spacing: 8) {
                        Text("•")
                            .foregroundColor(.secondary)
                        Text(text)
                    }
                }
            }
            .font(.body)

        case .numbered(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, text in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(idx + 1).")
                            .foregroundColor(.secondary)
                            .frame(width: 20, alignment: .trailing)
                        Text(text)
                    }
                }
            }
            .font(.body)

        case .code(let text):
            Text(text)
                .font(.system(.body, design: .monospaced))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 8))

        case .table(let headers, let rows):
            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack(spacing: 0) {
                    ForEach(headers, id: \.self) { h in
                        Text(h)
                            .font(.headline)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .background(Color.primary.opacity(0.1))

                // Rows
                ForEach(Array(rows.enumerated()), id: \.offset) { idx, row in
                    HStack(spacing: 0) {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(cell)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .background(idx % 2 == 0 ? Color.clear : Color.primary.opacity(0.03))
                    Divider()
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.1), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}
