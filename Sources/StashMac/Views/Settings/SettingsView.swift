import SwiftUI

/// Root of the Stash Settings scene (⌘,). Tabs: Capture (existing
/// ingest-related toggles), Appearance (theme picker), and Gemini
/// (API key + identify prompt).
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
            GeminiPrefsView()
                .tabItem {
                    Label("Gemini", systemImage: "sparkles")
                }
                .frame(minWidth: 560, minHeight: 480)
        }
        .frame(width: 640, height: 540)
    }
}
