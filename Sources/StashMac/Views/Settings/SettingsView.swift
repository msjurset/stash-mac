import SwiftUI

/// Root of the Stash Settings scene (⌘,). Tabs: Capture (existing
/// ingest-related toggles), Appearance (theme picker), and AI
/// (provider picker + API key + identify prompt).
struct SettingsView: View {
    var body: some View {
        TabView {
            CapturePrefsView()
                .tabItem {
                    Label("Capture", systemImage: "tray.and.arrow.down")
                }
                .frame(minWidth: 560, minHeight: 420)
            AppearancePrefsView()
                .tabItem {
                    Label("Appearance", systemImage: "paintpalette")
                }
                .frame(minWidth: 560, minHeight: 420)
            AIPrefsView()
                .tabItem {
                    Label("AI", systemImage: "sparkles")
                }
                .frame(minWidth: 560, minHeight: 540)
        }
        .frame(width: 640, height: 580)
    }
}
