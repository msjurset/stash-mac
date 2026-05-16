import SwiftUI

/// Modal for subscribing to a new feed source. Phase 2 of the Inbox
/// feature; surfaces the same options as `stash feeds add` on the
/// CLI — name + URL + kind, default tags & collection, auto-stash
/// toggle, poll interval.
///
/// Two kinds are exposed in the picker today:
///   - RSS / Atom: standard feed parser handles both
///   - YouTube channel: any channel URL form; the Go-side resolver
///     converts to the videos.xml feed before storing
///
/// On Add, polls immediately so the inbox doesn't sit empty waiting
/// for the next interval — same as `stash feeds add && stash feeds refresh`.
struct AddFeedSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(StashStore.self) private var store

    @State private var name = ""
    @State private var url = ""
    @State private var kind: Kind = .rss
    @State private var tagsInput = ""
    @State private var collection: String = ""
    @State private var autoStash = false
    @State private var intervalMinutes = 360
    @State private var saving = false
    @State private var errorMessage: String?

    enum Kind: String, CaseIterable, Identifiable {
        case rss     = "RSS / Atom"
        case youtube = "YouTube channel"
        var id: String { rawValue }
        var cliKind: String {
            switch self {
            case .rss:     return "rss"
            case .youtube: return "youtube"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Feed")
                .font(.title3).bold()

            Form {
                LabeledContent("Name") {
                    FilterField(placeholder: "Display name", text: $name, autoFocus: true)
                }
                LabeledContent("URL") {
                    FilterField(placeholder: kind == .youtube ? "youtube.com/@channel or feed URL" : "https://example.com/rss.xml",
                                text: $url)
                }
                LabeledContent("Kind") {
                    Picker("", selection: $kind) {
                        ForEach(Kind.allCases) { k in
                            Text(k.rawValue).tag(k)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                LabeledContent("Default tags") {
                    FilterField(placeholder: "comma-separated", text: $tagsInput)
                }
                LabeledContent("Default collection") {
                    Picker("", selection: $collection) {
                        Text("None").tag("")
                        ForEach(store.collections, id: \.name) { c in
                            Text(c.name).tag(c.name)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                LabeledContent("Auto-stash") {
                    Toggle("Skip triage; stash new candidates with the defaults above", isOn: $autoStash)
                        .toggleStyle(.checkbox)
                }
                LabeledContent("Poll every") {
                    HStack {
                        TextField("", value: $intervalMinutes, format: .number)
                            .frame(width: 80)
                        Text("minutes").foregroundStyle(.secondary)
                    }
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(saving ? "Adding…" : "Add") { Task { await commit() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit || saving)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private var canSubmit: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !url.trimmingCharacters(in: .whitespaces).isEmpty &&
        intervalMinutes > 0
    }

    private func commit() async {
        saving = true
        errorMessage = nil
        let tags = tagsInput
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        do {
            _ = try await StashCLI.shared.addFeedSource(
                name: name.trimmingCharacters(in: .whitespaces),
                url: url.trimmingCharacters(in: .whitespaces),
                kind: kind.cliKind,
                defaultTags: tags,
                defaultCollection: collection.isEmpty ? nil : collection,
                autoStash: autoStash,
                intervalMinutes: intervalMinutes
            )
            // Immediate poll so the inbox starts populating without
            // waiting for the next interval tick.
            store.pollFeeds()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        saving = false
    }
}
