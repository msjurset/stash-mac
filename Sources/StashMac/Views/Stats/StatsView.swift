import SwiftUI

struct StatsView: View {
    @Environment(StashStore.self) private var store

    var body: some View {
        ScrollView {
            if let stats = store.statsData {
                VStack(alignment: .leading, spacing: 20) {
                    overviewSection(stats)
                    storageSection(stats)
                    topTagsSection(stats.items)
                    growthSection(stats.items)
                }
                .padding()
            } else {
                ProgressView("Loading stats...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { store.loadStats() }
        .toolbar {
            ToolbarItem {
                Button {
                    store.loadStats()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh stats")
            }
        }
    }

    @ViewBuilder
    private func overviewSection(_ stats: StashStatsResponse) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Overview")
                .font(.headline)

            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible()),
            ], spacing: 12) {
                statCard("Items", value: "\(stats.items.totalItems)", icon: "tray.full")
                statCard("Tags", value: "\(stats.items.tagCount)", icon: "tag")
                statCard("Collections", value: "\(stats.items.collectionCount)", icon: "folder")
                statCard("Links", value: "\(stats.items.linkCount)", icon: "link")

                if let oldest = stats.items.oldestItem {
                    statCard("Oldest", value: oldest.formatted(date: .abbreviated, time: .omitted), icon: "calendar")
                }
                if let newest = stats.items.newestItem {
                    statCard("Newest", value: newest.formatted(date: .abbreviated, time: .omitted), icon: "calendar.badge.clock")
                }
            }

            if !stats.items.typeCounts.isEmpty {
                Divider()
                HStack(spacing: 16) {
                    ForEach(Array(stats.items.typeCounts.sorted(by: { $0.value > $1.value })), id: \.key) { type, count in
                        HStack(spacing: 4) {
                            Image(systemName: iconForType(type))
                                .foregroundStyle(.secondary)
                            Text("\(count)")
                                .font(.callout.monospacedDigit())
                            Text(type)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func storageSection(_ stats: StashStatsResponse) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Storage")
                .font(.headline)

            HStack(spacing: 24) {
                VStack(alignment: .leading) {
                    Text("Total")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(formatBytes(stats.diskTotal))
                        .font(.title2.monospacedDigit())
                }
                VStack(alignment: .leading) {
                    Text("Database")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(formatBytes(stats.diskDb))
                        .font(.callout.monospacedDigit())
                }
                VStack(alignment: .leading) {
                    Text("Files")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(formatBytes(stats.diskFiles))
                        .font(.callout.monospacedDigit())
                }
            }
        }
    }

    @ViewBuilder
    private func topTagsSection(_ items: StashStatsItems) -> some View {
        if !items.topTags.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Top Tags")
                    .font(.headline)

                let maxCount = items.topTags.first?.count ?? 1
                ForEach(items.topTags) { tag in
                    HStack(spacing: 8) {
                        Text(tag.name)
                            .frame(width: 120, alignment: .trailing)
                            .font(.callout)
                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(.blue.opacity(0.6))
                                .frame(width: max(4, geo.size.width * CGFloat(tag.count ?? 0) / CGFloat(max(maxCount, 1))))
                        }
                        .frame(height: 16)
                        Text("\(tag.count ?? 0)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 30, alignment: .trailing)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func growthSection(_ items: StashStatsItems) -> some View {
        if let months = items.monthCounts, !months.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Growth")
                    .font(.headline)

                let sorted = months.reversed()
                let maxCount = sorted.map(\.count).max() ?? 1
                ForEach(Array(sorted), id: \.month) { mc in
                    HStack(spacing: 8) {
                        Text(mc.month)
                            .frame(width: 70, alignment: .trailing)
                            .font(.caption.monospacedDigit())
                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(.green.opacity(0.6))
                                .frame(width: max(4, geo.size.width * CGFloat(mc.count) / CGFloat(max(maxCount, 1))))
                        }
                        .frame(height: 16)
                        Text("\(mc.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 30, alignment: .trailing)
                    }
                }
            }
        }
    }

    private func statCard(_ label: String, value: String, icon: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.monospacedDigit().bold())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func iconForType(_ type: String) -> String {
        switch type {
        case "url": return "link"
        case "snippet": return "doc.text"
        case "file": return "doc"
        case "image": return "photo"
        case "email": return "envelope"
        default: return "questionmark"
        }
    }
}
