import SwiftUI
import ReadiumNavigator

/// Resolves the user's `AppearancePreference` to a concrete Readium
/// `ReadiumNavigator.Theme`. Standalone (not a method) so it stays a pure
/// function with both inputs explicit, which is what the test exercises.
///
/// `.system` is resolved here — by the time the value crosses the
/// SwiftUI→UIKit bridge into `ReaderHost` / `ReaderContainerVC`, it is
/// always a concrete `.light` or `.dark`. The SwiftUI side is the only
/// layer that has `@Environment(\.colorScheme)` available to it for free.
func resolveReaderTheme(
    appearance: AppearancePreference,
    colorScheme: ColorScheme
) -> ReadiumNavigator.Theme {
    switch appearance {
    case .system: return colorScheme == .dark ? .dark : .light
    case .light:  return .light
    case .dark:   return .dark
    }
}
