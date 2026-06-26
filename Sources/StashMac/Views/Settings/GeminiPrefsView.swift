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
                StashTextEditor(text: $promptDraft, monospaced: true)
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

            // Usage / cost panel — only meaningful for Gemini today
            // (the cost table is gemini-specific). Hidden under
            // other providers so Claude users don't see misleading
            // gemini-rate numbers.
            if prefs.activeID == .gemini {
                GeminiUsageSection()
                GeminiDaemonConfigSection()
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

/// Gemini usage + cost forecaster panel. Reads from
/// GeminiUsageStore.shared, which the HTTP layer updates after
/// every successful identify response that carries usageMetadata.
/// Shows today's calls / tokens / cost, all-time totals, and a
/// 30-day projection so the user can spot a runaway-burn pattern
/// before the credit card surprise (the Recruit-style $11/mo lesson).
private struct GeminiUsageSection: View {
    @Bindable var store: GeminiUsageStore = .shared
    @Bindable var daemonStore: GeminiDaemonUsageStore = .shared

    var body: some View {
        let local = store.usage
        let daemon = daemonStore.usage
        let rate = GeminiPricing.rate(for: GeminiPricing.defaultModel)

        // Combined totals — sum the two stores at render time so
        // the user sees aggregate spend, with the breakdown rows
        // beneath for attribution.
        let combinedTodayCalls = local.todayCalls + daemon.todayCalls
        let combinedTodayInput = local.todayInputTokens + daemon.today.totalInputTokens
        let combinedTodayOutput = local.todayOutputTokens + daemon.today.totalOutputTokens
        let combinedTodayCost = local.todayCostUsd() + daemon.todayCostUsd()
        let combinedAllCalls = local.allTimeCalls + daemon.allTimeCalls
        let combinedAllInput = local.allTimeInputTokens + daemon.allTime.totalInputTokens
        let combinedAllOutput = local.allTimeOutputTokens + daemon.allTime.totalOutputTokens
        let combinedAllCost = local.allTimeCostUsd() + daemon.allTimeCostUsd()

        Section {
            UsageRow(
                label: "Today (\(local.date))",
                calls: combinedTodayCalls,
                inputTokens: combinedTodayInput,
                outputTokens: combinedTodayOutput,
                costUsd: combinedTodayCost
            )
            UsageRow(
                label: "All-time",
                calls: combinedAllCalls,
                inputTokens: combinedAllInput,
                outputTokens: combinedAllOutput,
                costUsd: combinedAllCost
            )
            if daemon.loaded {
                // Daemon contribution as a sub-row so the user
                // can see how much of the combined number came
                // from auto-identify vs. interactive Mac use.
                HStack {
                    Text("• Auto-identify (daemon)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(
                        "\(daemon.allTimeCalls) call\(daemon.allTimeCalls == 1 ? "" : "s") all-time · " +
                        "$\(String(format: "%.4f", daemon.allTimeCostUsd()))"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                }
            }
            if local.allTimeCalls + daemon.allTimeCalls > 0 {
                HStack {
                    Text("30-day projection")
                    Spacer()
                    // Forecast uses the Mac's local first-seen
                    // date for the day count — it's the most
                    // reliable anchor across daemon restarts.
                    let projected = (local.thirtyDayProjectionUsd() / max(local.allTimeCostUsd(), .leastNonzeroMagnitude))
                        * combinedAllCost
                    let dailyAvg = projected / 30.0
                    Text(
                        "≈ $\(String(format: "%.2f", projected.isFinite ? projected : 0)) " +
                        "($\(String(format: "%.4f", dailyAvg.isFinite ? dailyAvg : 0))/day avg)"
                    )
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                }
            }
            HStack {
                Button("Reset all-time") {
                    store.resetAllTime()
                }
                Spacer()
            }
        } header: {
            Text("Usage & cost")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(
                    "Tracks every Gemini call this app makes. Tokens come from Google's usageMetadata on each response. " +
                    "Cost is computed from current Gemini 2.5 Flash paid-tier rates " +
                    "($\(String(format: "%.2f", rate.inputPerMillion))/M input, $\(String(format: "%.2f", rate.outputPerMillion))/M output). " +
                    "Pair with a GCP billing budget alert for belt-and-suspenders."
                )
                Text("Rates loaded from \(GeminiPricing.configFileDisplayPath) (served to phones via gostash GET /pricing).")
                if daemon.loaded {
                    Text("Daemon spend read from \(GeminiDaemonUsageStore.ledgerDisplayPath) (written by `stash serve`).")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .onAppear { daemonStore.startPolling() }
        .onDisappear { daemonStore.stopPolling() }
    }
}

private struct UsageRow: View {
    let label: String
    let calls: Int
    let inputTokens: Int64
    let outputTokens: Int64
    let costUsd: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                Spacer()
                Text("\(calls) \(calls == 1 ? "call" : "calls") · $\(String(format: "%.4f", costUsd))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Text(
                "in \(formatTokens(inputTokens)) · out \(formatTokens(outputTokens))"
            )
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
    }
}

private func formatTokens(_ t: Int64) -> String {
    switch t {
    case 0..<1_000: return "\(t)"
    case 0..<1_000_000: return String(format: "%.1fk", Double(t) / 1_000)
    default: return String(format: "%.2fM", Double(t) / 1_000_000)
    }
}

private struct GeminiDaemonConfigSection: View {
    @Environment(AIPrefsStore.self) private var prefs
    @State private var loadedConfig: StashCLI.DaemonConfig? = nil
    @State private var isLoading = false
    @State private var saveStatus: SaveStatus = .idle

    @State private var globalPrimaryModelInput: String = ""
    @State private var modelsInput: String = ""
    @State private var selectedOp: String = "identify"
    @State private var opPrimaryModelInputs: [String: String] = [:]
    @State private var opFallbackModelsInputs: [String: String] = [:]

    @State private var dailyBudgetInput: String = ""
    @State private var monthlyBudgetInput: String = ""
    @State private var paidTierEnabled: Bool = false
    @State private var paidKeyInput: String = ""
    @State private var paidKeyRevealed: Bool = false
    @State private var paidApprovalDurationInput: String = ""
    @State private var maxVideoDurationInput: String = ""

    private enum SaveStatus: Equatable {
        case idle
        case saving
        case success
        case failed(String)
    }

    private func operationDisplayName(_ op: String) -> String {
        switch op {
        case "identify": return "Identify"
        case "search": return "Search"
        case "chat": return "Chat"
        case "ask": return "Ask"
        case "transform": return "Transform"
        default: return op.capitalized
        }
    }

    private func operationDescription(_ op: String) -> String {
        switch op {
        case "identify":
            return "Identify analyzes captured images, generates descriptive titles/notes, and transcribes text/handwriting."
        case "search":
            return "Search processes text embedding queries to enable semantic and conceptual library searches."
        case "chat":
            return "Chat drives conversational Q&A sessions across your entire library in the chat view."
        case "ask":
            return "Ask handles specific questions and details extraction targeting a single item."
        case "transform":
            return "Transform runs prompt templates to rewrite, summarize, or extract structured fields from item content."
        default:
            return ""
        }
    }

    private var isDirty: Bool {
        guard let config = loadedConfig else { return false }
        
        let loadedPrimary = config.primaryModel ?? ""
        if globalPrimaryModelInput.trimmingCharacters(in: .whitespacesAndNewlines) != loadedPrimary {
            return true
        }

        let loadedModels = config.aiModels?.joined(separator: ", ") ?? ""
        if modelsInput.trimmingCharacters(in: .whitespacesAndNewlines) != loadedModels {
            return true
        }
        
        let ops = ["identify", "search", "chat", "ask", "transform"]
        for op in ops {
            let loadedOpPrimary = config.operations?[op]?.primaryModel ?? ""
            let currentOpPrimary = opPrimaryModelInputs[op] ?? ""
            if currentOpPrimary.trimmingCharacters(in: .whitespacesAndNewlines) != loadedOpPrimary {
                return true
            }
            
            let loadedOpFallbacks = config.operations?[op]?.aiModels?.joined(separator: ", ") ?? ""
            let currentOpFallbacks = opFallbackModelsInputs[op] ?? ""
            if currentOpFallbacks.trimmingCharacters(in: .whitespacesAndNewlines) != loadedOpFallbacks {
                return true
            }
        }

        let loadedDaily = String(format: "%.2f", config.maxDailyBudgetUsd ?? 0.0)
        let inputDaily = Double(dailyBudgetInput) ?? 0.0
        let currentDailyStr = String(format: "%.2f", inputDaily)
        if currentDailyStr != loadedDaily && !dailyBudgetInput.isEmpty {
            return true
        }

        let loadedMonthly = String(format: "%.2f", config.maxMonthlyBudgetUsd ?? 0.0)
        let inputMonthly = Double(monthlyBudgetInput) ?? 0.0
        let currentMonthlyStr = String(format: "%.2f", inputMonthly)
        if currentMonthlyStr != loadedMonthly && !monthlyBudgetInput.isEmpty {
            return true
        }

        let loadedMaxVideo = String(config.maxVideoDurationMinutes ?? 30)
        if maxVideoDurationInput != loadedMaxVideo && !maxVideoDurationInput.isEmpty {
            return true
        }

        let loadedApproval = String(config.paidApprovalDurationHours ?? 24)
        if paidApprovalDurationInput != loadedApproval && !paidApprovalDurationInput.isEmpty {
            return true
        }

        if paidTierEnabled != (config.paidTierEnabled ?? false) {
            return true
        }

        if !paidKeyInput.isEmpty {
            return true
        }

        return false
    }

    var body: some View {
        Section {
            if isLoading {
                HStack {
                    Spacer()
                    ProgressView().controlSize(.small)
                    Spacer()
                }
            } else {
                // Primary Model Field
                VStack(alignment: .leading, spacing: 4) {
                    Text("Global Primary Model").font(.caption).foregroundStyle(.secondary)
                    ModelAutocompleteField(
                        placeholder: "e.g. gemini-2.5-flash",
                        text: $globalPrimaryModelInput,
                        isMultiValue: false,
                        providerID: prefs.activeID
                    )
                }

                // Fallback Models Field
                VStack(alignment: .leading, spacing: 4) {
                    Text("Global Fallback Models").font(.caption).foregroundStyle(.secondary)
                    ModelAutocompleteField(
                        placeholder: "e.g. gemini-2.5-flash, gemini-3.1-flash, gemini-2.5-flash-lite, gemini-3.5-flash",
                        text: $modelsInput,
                        isMultiValue: true,
                        providerID: prefs.activeID
                    )
                }

                // Operation overrides picker
                VStack(alignment: .leading, spacing: 4) {
                    Text("Operation-Specific Overrides").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: $selectedOp) {
                        ForEach(["identify", "search", "chat", "ask", "transform"], id: \.self) { op in
                            Text(operationDisplayName(op))
                                .tag(op)
                                .help(operationDescription(op))
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    Text(operationDescription(selectedOp))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Inputs for selected operation
                VStack(alignment: .leading, spacing: 8) {
                    let op = selectedOp
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(operationDisplayName(op)) Primary Model Override").font(.caption).foregroundStyle(.secondary)
                        ModelAutocompleteField(
                            placeholder: "Use Global Default (\(globalPrimaryModelInput.isEmpty ? "gemini-2.5-flash" : globalPrimaryModelInput))",
                            text: Binding(
                                get: { opPrimaryModelInputs[op] ?? "" },
                                set: { opPrimaryModelInputs[op] = $0 }
                            ),
                            isMultiValue: false,
                            providerID: prefs.activeID
                        )
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(operationDisplayName(op)) Fallback Models Override").font(.caption).foregroundStyle(.secondary)
                        ModelAutocompleteField(
                            placeholder: "Use Global Default (\(modelsInput.isEmpty ? "None" : modelsInput))",
                            text: Binding(
                                get: { opFallbackModelsInputs[op] ?? "" },
                                set: { opFallbackModelsInputs[op] = $0 }
                            ),
                            isMultiValue: true,
                            providerID: prefs.activeID
                        )
                    }
                }
                .padding(8)
                .background(Color.secondary.opacity(0.05))
                .cornerRadius(6)

                // Budgets
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Daily Budget ($ USD)").font(.caption).foregroundStyle(.secondary)
                        FilterField(
                            placeholder: "0.00",
                            text: $dailyBudgetInput,
                            isBordered: true,
                            backgroundColor: .textBackgroundColor
                        )
                        .frame(height: 22)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Monthly Budget ($ USD)").font(.caption).foregroundStyle(.secondary)
                        FilterField(
                            placeholder: "0.00",
                            text: $monthlyBudgetInput,
                            isBordered: true,
                            backgroundColor: .textBackgroundColor
                        )
                        .frame(height: 22)
                    }
                }

                // Max Video Duration / Paid Approval Duration
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Max Video Duration (mins)").font(.caption).foregroundStyle(.secondary)
                        FilterField(
                            placeholder: "30",
                            text: $maxVideoDurationInput,
                            isBordered: true,
                            backgroundColor: .textBackgroundColor
                        )
                        .frame(height: 22)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Paid Approval Duration (hours)").font(.caption).foregroundStyle(.secondary)
                        FilterField(
                            placeholder: "24",
                            text: $paidApprovalDurationInput,
                            isBordered: true,
                            backgroundColor: .textBackgroundColor
                        )
                        .frame(height: 22)
                    }
                }

                // Paid Tier Toggle
                Toggle("Enable Paid API Key Tier", isOn: $paidTierEnabled)
                    .padding(.vertical, 4)

                // Paid API Key
                if paidTierEnabled {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Paid API Key or 1Password Reference").font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            if paidKeyRevealed {
                                FilterField(
                                    placeholder: loadedConfig?.paidCredentialSet == true ? "•••••••• (Saved)" : "op://vault/item/field or AI key...",
                                    text: $paidKeyInput,
                                    isBordered: true,
                                    backgroundColor: .textBackgroundColor
                                )
                                .frame(height: 22)
                            } else {
                                SecureField(
                                    "",
                                    text: $paidKeyInput,
                                    prompt: Text(loadedConfig?.paidCredentialSet == true ? "•••••••• (Saved)" : "op://vault/item/field or AI key...")
                                )
                                .textFieldStyle(.roundedBorder)
                                .labelsHidden()
                            }
                            Button {
                                paidKeyRevealed.toggle()
                            } label: {
                                Image(systemName: paidKeyRevealed ? "eye.slash" : "eye")
                            }
                            .buttonStyle(.borderless)
                            .help(paidKeyRevealed ? "Hide" : "Show")
                        }
                    }
                }

                // Status and Action buttons
                HStack(spacing: 8) {
                    Button("Save Daemon Settings") {
                        Task { await saveConfig() }
                    }
                    .disabled(saveStatus == .saving || !isDirty)

                    switch saveStatus {
                    case .idle:
                        EmptyView()
                    case .saving:
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Saving…").font(.caption).foregroundStyle(.secondary)
                        }
                    case .success:
                        Text("Saved successfully ✓")
                            .font(.caption)
                            .foregroundStyle(.green)
                    case .failed(let msg):
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding(.top, 4)
            }
        } header: {
            Text("Daemon Primary, Fallback & Budget Settings")
        } footer: {
            Text("These settings configure the background daemon (`stash serve`) used for automated media transcription, ingestion, and mobile access.\n\nGlobal primary and fallback models apply to all operations unless overridden. Per-operation overrides configure paths specifically for Identify, Search, Chat, Ask, or Transform.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear {
            Task { await loadConfig() }
        }
    }

    private func loadConfig() async {
        isLoading = true
        do {
            let config = try await StashCLI.shared.getDaemonConfig()
            self.loadedConfig = config
            
            self.globalPrimaryModelInput = config.primaryModel ?? ""
            self.modelsInput = config.aiModels?.joined(separator: ", ") ?? ""
            
            let ops = ["identify", "search", "chat", "ask", "transform"]
            var opPrimaries: [String: String] = [:]
            var opFallbacks: [String: String] = [:]
            for op in ops {
                opPrimaries[op] = config.operations?[op]?.primaryModel ?? ""
                opFallbacks[op] = config.operations?[op]?.aiModels?.joined(separator: ", ") ?? ""
            }
            self.opPrimaryModelInputs = opPrimaries
            self.opFallbackModelsInputs = opFallbacks

            self.dailyBudgetInput = String(format: "%.2f", config.maxDailyBudgetUsd ?? 0.0)
            self.monthlyBudgetInput = String(format: "%.2f", config.maxMonthlyBudgetUsd ?? 0.0)
            self.maxVideoDurationInput = String(config.maxVideoDurationMinutes ?? 30)
            self.paidApprovalDurationInput = String(config.paidApprovalDurationHours ?? 24)
            self.paidTierEnabled = config.paidTierEnabled ?? false
            self.paidKeyInput = ""
            
            self.saveStatus = .idle
        } catch {
            self.saveStatus = .failed("Failed to load daemon config: \(error.localizedDescription)")
        }
        isLoading = false
    }

    private func saveConfig() async {
        saveStatus = .saving
        do {
            let cli = StashCLI.shared
            
            if let config = loadedConfig {
                let loadedPrimary = config.primaryModel ?? ""
                if globalPrimaryModelInput.trimmingCharacters(in: .whitespacesAndNewlines) != loadedPrimary {
                    try await cli.setDaemonConfig(key: "primary_model", value: globalPrimaryModelInput)
                }

                let loadedModels = config.aiModels?.joined(separator: ", ") ?? ""
                if modelsInput.trimmingCharacters(in: .whitespacesAndNewlines) != loadedModels {
                    try await cli.setDaemonConfig(key: "ai_models", value: modelsInput)
                }
                
                let ops = ["identify", "search", "chat", "ask", "transform"]
                for op in ops {
                    let loadedOpPrimary = config.operations?[op]?.primaryModel ?? ""
                    let currentOpPrimary = opPrimaryModelInputs[op] ?? ""
                    if currentOpPrimary.trimmingCharacters(in: .whitespacesAndNewlines) != loadedOpPrimary {
                        try await cli.setDaemonConfig(key: "operations.\(op).primary_model", value: currentOpPrimary)
                    }
                    
                    let loadedOpFallbacks = config.operations?[op]?.aiModels?.joined(separator: ", ") ?? ""
                    let currentOpFallbacks = opFallbackModelsInputs[op] ?? ""
                    if currentOpFallbacks.trimmingCharacters(in: .whitespacesAndNewlines) != loadedOpFallbacks {
                        try await cli.setDaemonConfig(key: "operations.\(op).ai_models", value: currentOpFallbacks)
                    }
                }

                let loadedDaily = String(format: "%.2f", config.maxDailyBudgetUsd ?? 0.0)
                let inputDaily = Double(dailyBudgetInput) ?? 0.0
                let currentDailyStr = String(format: "%.2f", inputDaily)
                if currentDailyStr != loadedDaily {
                    try await cli.setDaemonConfig(key: "max_daily_budget_usd", value: currentDailyStr)
                }

                let loadedMonthly = String(format: "%.2f", config.maxMonthlyBudgetUsd ?? 0.0)
                let inputMonthly = Double(monthlyBudgetInput) ?? 0.0
                let currentMonthlyStr = String(format: "%.2f", inputMonthly)
                if currentMonthlyStr != loadedMonthly {
                    try await cli.setDaemonConfig(key: "max_monthly_budget_usd", value: currentMonthlyStr)
                }

                let loadedMaxVideo = String(config.maxVideoDurationMinutes ?? 30)
                if maxVideoDurationInput != loadedMaxVideo {
                    try await cli.setDaemonConfig(key: "max_video_duration_minutes", value: maxVideoDurationInput)
                }

                let loadedApproval = String(config.paidApprovalDurationHours ?? 24)
                if paidApprovalDurationInput != loadedApproval {
                    try await cli.setDaemonConfig(key: "paid_approval_duration_hours", value: paidApprovalDurationInput)
                }

                if paidTierEnabled != (config.paidTierEnabled ?? false) {
                    try await cli.setDaemonConfig(key: "paid_tier_enabled", value: paidTierEnabled ? "true" : "false")
                }

                if !paidKeyInput.isEmpty {
                    try await cli.setDaemonConfig(key: "paid_credential", value: paidKeyInput)
                }
            }
            
            let config = try await cli.getDaemonConfig()
            self.loadedConfig = config
            
            self.globalPrimaryModelInput = config.primaryModel ?? ""
            self.modelsInput = config.aiModels?.joined(separator: ", ") ?? ""
            
            let ops = ["identify", "search", "chat", "ask", "transform"]
            var opPrimaries: [String: String] = [:]
            var opFallbacks: [String: String] = [:]
            for op in ops {
                opPrimaries[op] = config.operations?[op]?.primaryModel ?? ""
                opFallbacks[op] = config.operations?[op]?.aiModels?.joined(separator: ", ") ?? ""
            }
            self.opPrimaryModelInputs = opPrimaries
            self.opFallbackModelsInputs = opFallbacks

            self.dailyBudgetInput = String(format: "%.2f", config.maxDailyBudgetUsd ?? 0.0)
            self.monthlyBudgetInput = String(format: "%.2f", config.maxMonthlyBudgetUsd ?? 0.0)
            self.maxVideoDurationInput = String(config.maxVideoDurationMinutes ?? 30)
            self.paidApprovalDurationInput = String(config.paidApprovalDurationHours ?? 24)
            self.paidTierEnabled = config.paidTierEnabled ?? false
            self.paidKeyInput = ""
            
            saveStatus = .success
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                if case .success = self.saveStatus {
                    self.saveStatus = .idle
                }
            }
        } catch {
            saveStatus = .failed("Failed to save: \(error.localizedDescription)")
        }
    }
}
