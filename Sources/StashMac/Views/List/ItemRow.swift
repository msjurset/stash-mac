import SwiftUI

struct ItemRow: View {
    @Environment(StashStore.self) private var store
    let item: StashItem

    private var isUnseen: Bool {
        store.isUnseen(item.id)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.type.icon)
                .foregroundStyle(isUnseen ? .primary : .secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .lineLimit(1)
                    .font(.body)
                    .fontWeight(isUnseen ? .bold : .regular)
                    .foregroundStyle(isUnseen ? .blue : .primary)

                HStack(spacing: 6) {
                    if let lang = item.language {
                        Text(lang)
                            .font(.caption2.monospaced())
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.blue.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(.blue)
                    }
                    if let tags = item.tags, !tags.isEmpty {
                        Text(tags.map { "#\($0.name)" }.joined(separator: " "))
                            .kerning(0.5)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            Text(item.createdAt, style: .relative)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
