import SwiftUI
import ReadiumNavigator

/// Resolves the user's `AppearancePreference` to a concrete Readium
/// `ReadiumNavigator.Theme`. Caseless-enum namespace + `static func`
/// mirrors `FontSizeStep` and `SwipeDismissPolicy` in
/// `ReaderGestureHelpers.swift` — every pure helper in the reader area
/// uses this shape so callers can read `<Namespace>.<verb>(...)`.
///
/// `.system` is resolved here — by the time the value crosses the
/// SwiftUI→UIKit bridge into `ReaderHost` / `ReaderContainerVC`, it is
/// always a concrete `.light` or `.dark`. The SwiftUI side is the only
/// layer that has `@Environment(\.colorScheme)` available to it for free.
enum ReaderThemeResolution {
    static func resolve(
        appearance: AppearancePreference,
        colorScheme: ColorScheme
    ) -> ReadiumNavigator.Theme {
        switch appearance {
        case .system: return colorScheme == .dark ? .dark : .light
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}
