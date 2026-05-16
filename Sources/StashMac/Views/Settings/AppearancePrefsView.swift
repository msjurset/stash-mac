import SwiftUI

/// Appearance preferences pane: at the moment just the System / Dark /
/// Light theme picker. Persisted via `@AppStorage("appTheme")`;
/// `StashMacApp` reads the same key and applies
/// `.preferredColorScheme(...)` to its main WindowGroup so the change
/// takes effect immediately, no relaunch needed.
struct AppearancePrefsView: View {
    @AppStorage("appTheme") private var theme: AppTheme = .system

    var body: some View {
        Form {
            Section("Appearance") {
                LabeledContent("Theme") {
                    Picker("Theme", selection: $theme) {
                        ForEach(AppTheme.allCases) { t in
                            Text(t.label).tag(t)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 320)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
