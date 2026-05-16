import SwiftUI

/// Root of the Stash Settings scene (⌘,). Tabs: Capture (existing
/// ingest-related toggles) and Appearance (theme picker).
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
        }
        .frame(width: 620, height: 480)
    }
}
