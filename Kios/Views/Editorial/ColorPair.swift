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
    ///
    /// The `@available(iOS, …, obsoleted: 18, …)` gate makes the extension
    /// invisible on iOS 18+, where Apple's native init takes over. When the
    /// project's deployment target eventually bumps to 18, the compiler will
    /// flag this whole extension as dead — at that point delete the file.
    @available(iOS, introduced: 17, obsoleted: 18,
               message: "iOS 18+ has Color(light:dark:) natively; remove this shim.")
    init(light: Color, dark: Color) {
        self.init(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(dark)
                : UIColor(light)
        })
    }
}
