import SwiftUI

/// Unified create sheet for the merged Collections section. Header
/// has the "New …" title on the left and a small **Smart Collection**
/// toggle on the right; flipping the toggle swaps the body between
/// the regular collection form (default) and the smart-collection
/// form. "Static" never appears in the UI — the toggle's off-state
/// is implicitly "regular collection".
struct CollectionCreateSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var smart: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(smart ? "New Smart Collection" : "New Collection")
                    .font(.headline)
                Spacer()
                Toggle("Smart Collection", isOn: $smart)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .help("Smart collections are saved queries that recompute on view. Off = a regular curated collection that accepts dropped items.")
            }
            Divider()

            Group {
                if smart {
                    // Reuses the existing smart-collection form. It
                    // does its own dismiss internally so we just
                    // host it. Negative padding offsets the form's
                    // own outer chrome so it doesn't double-frame.
                    SmartCollectionSheet(editing: nil)
                        .padding(.horizontal, -20)
                        .padding(.top, -8)
                } else {
                    StaticCollectionForm(onDone: { dismiss() })
                }
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

private struct StaticCollectionForm: View {
    @Environment(StashStore.self) private var store
    let onDone: () -> Void

    @State private var name = ""
    @State private var description = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("A user-curated set of items. Drag rows from the main list onto the collection in the sidebar to add them.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            StashField("Name", text: $name)
            StashField("Description", text: $description, prompt: "Optional")
            HStack {
                Spacer()
                Button("Cancel") { onDone() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    store.createCollection(
                        name: name,
                        description: description.isEmpty ? nil : description
                    )
                    onDone()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}
