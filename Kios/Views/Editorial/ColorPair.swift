import SwiftUI
import UIKit

extension Color {
    /// iOS 17 compatibility wrapper for `Color(light:dark:)`, which Apple ships
    /// natively in iOS 18+. Resolves via `UIColor(dynamicProvider:)` based on
    /// the trait collection's `userInterfaceStyle`.
    ///
    /// Used by `EditorialTheme` to give every design token a paired
    /// light/dark variant. Call sites stay unchanged
    /// (`EditorialTheme.ink`, `EditorialTheme.bg`, …); SwiftUI resolves
    /// per-view based on the active `@Environment(\.colorScheme)`.
    init(light: Color, dark: Color) {
        self.init(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(dark)
                : UIColor(light)
        })
    }
}
