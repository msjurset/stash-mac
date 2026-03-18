import SwiftUI

struct HelpView: View {
    @State private var selectedTopic: HelpTopic? = .gettingStarted

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

        case .code(let text):
            Text(text)
                .font(.system(.body, design: .monospaced))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 6))

        case .table(let headers, let rows):
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
                GridRow {
                    ForEach(headers, id: \.self) { header in
                        Text(header)
                            .font(.headline)
                    }
                }
                Divider()
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { colIdx, cell in
                            if colIdx == 0 {
                                Text(cell)
                                    .font(.system(.body, design: .monospaced))
                            } else {
                                Text(cell)
                                    .font(.body)
                            }
                        }
                    }
                }
            }
            .padding(12)
            .background(.quaternary.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 6))

        case .bullet(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 8) {
                        Text("•")
                            .foregroundStyle(.secondary)
                        Text(item)
                            .font(.body)
                    }
                }
            }
            .padding(.leading, 4)

        case .numbered(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(idx + 1).")
                            .foregroundStyle(.secondary)
                            .frame(width: 20, alignment: .trailing)
                        Text(item)
                            .font(.body)
                    }
                }
            }
            .padding(.leading, 4)
        }
    }
}

/// Contextual help button with proper macOS styling.
struct ContextualHelpButton: View {
    let topic: HelpTopic
    @State private var showPopover = false

    var body: some View {
        Button(action: { showPopover.toggle() }) {
            Image(systemName: "questionmark.circle")
        }
        .help("Help: \(topic.rawValue)")
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            ScrollView {
                HelpDetailView(topic: topic)
            }
            .frame(width: 500, height: 420)
        }
    }
}
