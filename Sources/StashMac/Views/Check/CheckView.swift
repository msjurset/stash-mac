import SwiftUI

struct CheckView: View {
    @Environment(StashStore.self) private var store

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if store.isCheckRunning {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text("Running checks...")
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 40)
                } else if let result = store.checkResult {
                    resultView(result)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.shield")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("Run a health check on your stash")
                            .foregroundStyle(.secondary)
                        Button("Run Check") {
                            store.runCheck()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 40)
                }
            }
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar {
            ToolbarItem {
                Button {
                    store.runCheck()
                } label: {
                    Label("Run Check", systemImage: "arrow.clockwise")
                }
                .help("Run health check")
                .disabled(store.isCheckRunning)
            }
        }
    }

    @ViewBuilder
    private func resultView(_ result: CheckResult) -> some View {
        if result.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.green)
                Text("No issues found")
                    .font(.headline)
                Text("Your stash is healthy.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 40)
        } else {
            Text("\(result.totalIssues) issue(s) found")
                .font(.headline)

            if let broken = result.brokenUrls, !broken.isEmpty {
                issueSection("Broken URLs", icon: "link.badge.plus", color: .red, items: broken)
            }

            if let missing = result.missingFiles, !missing.isEmpty {
                issueSection("Missing Files", icon: "doc.badge.ellipsis", color: .orange, items: missing)
            }

            if let orphaned = result.orphanedFiles, !orphaned.isEmpty {
                orphanedSection(orphaned)
            }

            if let dupes = result.duplicateHashes, !dupes.isEmpty {
                dupeSection(dupes)
            }
        }
    }

    @ViewBuilder
    private func issueSection(_ title: String, icon: String, color: Color, items: [CheckIssue]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("\(title) (\(items.count))", systemImage: icon)
                .font(.subheadline.bold())
                .foregroundStyle(color)

            ForEach(items) { issue in
                HStack {
                    Text(issue.title)
                        .lineLimit(1)
                    Spacer()
                    if let detail = issue.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.vertical, 2)
                .padding(.horizontal, 8)
            }
        }
    }

    @ViewBuilder
    private func orphanedSection(_ files: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Orphaned Files (\(files.count))", systemImage: "doc.badge.gearshape")
                .font(.subheadline.bold())
                .foregroundStyle(.yellow)

            ForEach(files, id: \.self) { file in
                Text(file)
                    .font(.callout.monospaced())
                    .padding(.vertical, 2)
                    .padding(.horizontal, 8)
            }
        }
    }

    @ViewBuilder
    private func dupeSection(_ groups: [DupeGroup]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Duplicate Content (\(groups.count) groups)", systemImage: "doc.on.doc")
                .font(.subheadline.bold())
                .foregroundStyle(.purple)

            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hash: \(String(group.hash.prefix(16)))...")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    ForEach(group.items) { item in
                        HStack {
                            Text(item.title)
                                .lineLimit(1)
                            Spacer()
                            Text(String(item.id.prefix(10)))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.leading, 12)
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
            }
        }
    }
}
