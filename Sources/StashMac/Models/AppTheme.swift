import SwiftUI

/// Light / dark / follow-the-OS theme preference. Persisted via
/// `@AppStorage("appTheme")`. Maps to SwiftUI's `ColorScheme?` for
/// the `.preferredColorScheme(_:)` modifier — `nil` means "let the
/// system decide", which is the default the user sees on first run.
enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case dark
    case light

    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "System"
        case .dark:   return "Dark"
        case .light:  return "Light"
        }
    }

    /// nil = follow the system; otherwise force the matching scheme.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .dark:   return .dark
        case .light:  return .light
        }
    }
}
