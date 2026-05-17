import SwiftUI

/// Settings tab for the Mac-side AI integration. Provider-agnostic:
/// the active provider is picked at the top of the pane, and the
/// API-key field + prompt editor below operate on whatever's
/// currently selected. New providers (Claude, OpenAI, …) plug in via
/// `AIProviderRegistry` and appear here automatically.
struct AIPrefsView: View {
    @Environment(AIPrefsStore.self) private var prefs

    @State private var keyField: String = ""
    @State private var keyRevealed = false
    @State private var promptDraft: String = ""
    @State private var testStatus: TestStatus = .idle

    private enum TestStatus: Equatable {
        case idle
        case pending
        case ok
        case failed(String)
    }

    var body: some View {
        Form {
            Section {
                providerPicker
            } header: {
                Text("Provider")
            } footer: {
                Text("Each provider keeps its own key and prompt. Switching here only changes which one the right-click → Identify menu uses.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                keyRow
                HStack(spacing: 8) {
                    Button("Save") {
                        prefs.setKey(keyField)
                        // Reflect the cleaned value back into the
                        // editor (e.g. stripped surrounding quotes)
                        // so the user sees what was actually saved.
                        keyField = prefs.apiKey
                        testStatus = .idle
                    }
                    .disabled(keyField.trimmingCharacters(in: .whitespaces).isEmpty
                              || keyField == prefs.apiKey)
                    Button("Test") {
                        Task { await testKey() }
                    }
                    .disabled(keyField.trimmingCharacters(in: .whitespaces).isEmpty
                              || testStatus == .pending)
                    if prefs.hasKey {
                        Button("Clear") {
                            prefs.setKey("")
                            keyField = ""
                            testStatus = .idle
                        }
                    }
                    Spacer()
                    Link("Get a key →", destination: prefs.activeProvider.keyURL)
                        .font(.caption)
                }
                onePasswordHint
                statusLine
            } header: {
                Text("API key")
            } footer: {
                Text("Used to identify image items via right-click → Identify with \(prefs.activeProvider.displayName). The key never leaves this Mac.\n\nPaste an `op://vault/item/field` reference to resolve the secret via the 1Password CLI on every request — install with `brew install 1password-cli`.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                TextEditor(text: $promptDraft)
                    .font(.body.monospaced())
                    .frame(minHeight: 160)
                    .overlay(alignment: .bottomTrailing) {
                        Text("\(promptDraft.count) chars")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(6)
                    }
                HStack(spacing: 8) {
                    Button("Save Prompt") {
                        prefs.setPrompt(promptDraft)
                    }
                    .disabled(promptDraft == prefs.promptText)
                    Button("Reset to default") {
                        prefs.resetPrompt()
                        promptDraft = prefs.promptText
                    }
                    .disabled(prefs.promptText == prefs.activeProvider.defaultPrompt)
                }
            } header: {
                Text("Identify prompt")
            } footer: {
                Text("Sent to \(prefs.activeProvider.displayName) with every photo. The default asks for `TITLE:` and `NOTES:` lines so the response slots into the item's Title and Notes fields. Edit freely — the parser handles `Common Name:` / free-form fallbacks too.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .onAppear {
            keyField = prefs.apiKey
            promptDraft = prefs.promptText
        }
    }

    private var providerPicker: some View {
        Picker(selection: Binding(
            get: { prefs.activeID },
            set: { newID in
                prefs.setActiveProvider(newID)
                // Repopulate the editors so they reflect the
                // newly-selected provider's stored values.
                keyField = prefs.apiKey
                promptDraft = prefs.promptText
                testStatus = .idle
            }
        )) {
            ForEach(AIProviderID.allCases) { id in
                Text(AIProviderRegistry.provider(for: id).displayName).tag(id)
            }
        } label: {
            EmptyView()
        }
        .labelsHidden()
        .pickerStyle(.radioGroup)
    }

    private var keyRow: some View {
        HStack(spacing: 6) {
            if keyRevealed {
                // FilterField (NoAutoFillTextField under the hood) — required
                // to keep the phantom autofill popup suppressed. Never swap
                // back to SwiftUI's `TextField` here.
                FilterField(
                    placeholder: prefs.activeProvider.keyPlaceholder,
                    text: $keyField,
                    isBordered: true,
                    backgroundColor: .textBackgroundColor
                )
                .frame(height: 22)
            } else {
                // Use the `prompt:` parameter so the placeholder renders
                // INSIDE the field. `.labelsHidden()` keeps Form's grouped
                // style from promoting the title string into a left-side
                // row label.
                SecureField(
                    "",
                    text: $keyField,
                    prompt: Text(prefs.activeProvider.keyPlaceholder)
                )
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
            }
            Button {
                keyRevealed.toggle()
            } label: {
                Image(systemName: keyRevealed ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
            .help(keyRevealed ? "Hide" : "Show")
        }
    }

    /// Inline hint when the user has pasted an `op://` reference.
    /// Confirms 1Password CLI mode is engaged, and flags it when the
    /// `op` binary isn't on disk so the user can fix the install
    /// before hitting Test / Identify.
    @ViewBuilder
    private var onePasswordHint: some View {
        if AIKeyResolver.isReference(keyField) {
            HStack(spacing: 6) {
                Image(systemName: AIKeyResolver.opAvailable
                      ? "lock.shield"
                      : "exclamationmark.triangle")
                    .foregroundStyle(AIKeyResolver.opAvailable
                                     ? Color.secondary
                                     : Color.yellow)
                if AIKeyResolver.opAvailable {
                    Text("Resolved via 1Password CLI on each request.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("1Password CLI not found — `brew install 1password-cli` then `op signin`.")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                }
            }
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch testStatus {
        case .idle:
            EmptyView()
        case .pending:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Testing key…").font(.caption).foregroundStyle(.secondary)
            }
        case .ok:
            Text("Key works ✓")
                .font(.caption)
                .foregroundStyle(.green)
        case .failed(let msg):
            Text(msg)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private func testKey() async {
        let trimmed = keyField.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        testStatus = .pending
        do {
            // Resolve `op://...` references the same way the
            // identify path does, so Test exercises the full
            // 1Password CLI → provider round trip.
            let resolved = try await AIKeyResolver.resolve(trimmed)
            try await prefs.activeProvider.testKey(resolved)
            testStatus = .ok
        } catch {
            testStatus = .failed(describe(error))
        }
    }

    private func describe(_ error: Error) -> String {
        let msg = (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
        return msg
    }
}
