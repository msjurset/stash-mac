import SwiftUI

/// Settings tab for the Mac-side Gemini integration. Same shape as
/// the Android Settings → Gemini section: API key field with
/// reveal/hide toggle, editable prompt with Reset to default, and a
/// Test button that does a cheap key-validity round trip.
struct GeminiPrefsView: View {
    @Environment(GeminiPrefsStore.self) private var prefs

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
                keyRow
                HStack(spacing: 8) {
                    Button("Save") {
                        prefs.setKey(keyField)
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
                    Link("Get a key →", destination: URL(string: "https://aistudio.google.com/app/apikey")!)
                        .font(.caption)
                }
                statusLine
            } header: {
                Text("API key")
            } footer: {
                Text("Used to identify image items via right-click → Identify with Gemini. The key never leaves this Mac.")
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
                    .disabled(prefs.promptText == GeminiDefaultPrompt.value)
                }
            } header: {
                Text("Identify prompt")
            } footer: {
                Text("Sent to Gemini with every photo. The default asks for `TITLE:` and `NOTES:` lines so the response slots into the item's Title and Notes fields. Edit freely — the parser handles `Common Name:` / free-form fallbacks too.")
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

    private var keyRow: some View {
        HStack(spacing: 6) {
            if keyRevealed {
                // FilterField (NoAutoFillTextField under the hood) — required
                // to keep the phantom autofill popup suppressed. Never swap
                // back to SwiftUI's `TextField` here.
                FilterField(
                    placeholder: "AIza…",
                    text: $keyField,
                    isBordered: true,
                    backgroundColor: .textBackgroundColor
                )
                .frame(height: 22)
            } else {
                SecureField("AIza…", text: $keyField)
                    .textFieldStyle(.roundedBorder)
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
            try await GeminiClient().testKey(trimmed)
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
