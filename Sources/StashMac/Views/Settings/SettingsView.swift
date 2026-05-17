import SwiftUI

/// Root of the Stash Settings scene (⌘,). Tabs: Capture (existing
/// ingest-related toggles), Appearance (theme picker), AI (provider
/// picker + API key + identify prompt), and Pairing (QR for the
/// Android app, manual-entry fallback, token rotation).
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
            PairingPrefsView()
                .tabItem {
                    Label("Pairing", systemImage: "qrcode")
                }
                .frame(minWidth: 560, minHeight: 540)
        }
        .frame(width: 640, height: 600)
    }
}
