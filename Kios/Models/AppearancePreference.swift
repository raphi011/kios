import SwiftUI

/// User-facing app appearance preference, stored at `@AppStorage(.appearance)`
/// (typed key defined in `Kios/App/Preferences.swift`).
///
/// Drives two surfaces:
///   1. SwiftUI chrome via `.preferredColorScheme(_:)` applied at the
///      WindowGroup root (`KiosApp`). Propagates `@Environment(\.colorScheme)`
///      down to every Editorial view.
///   2. EPUB content rendering inside Readium via
///      `ReaderThemeResolution.resolve(appearance:colorScheme:)` (defined in
///      `Kios/Views/Reader/ReaderThemeResolution.swift`), which maps to
///      `ReadiumNavigator.Theme`.
///
/// The two surfaces are coupled by design — one preference, two
/// destinations. Sepia and an independent reader theme are intentionally
/// out of scope; revisit if a future requirement demands them.
enum AppearancePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    /// Maps to SwiftUI's `preferredColorScheme` input. `nil` lets iOS drive
    /// (Settings → Display & Brightness or the per-time auto schedule).
    var swiftUIScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}
