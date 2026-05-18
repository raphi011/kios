import Testing
import SwiftUI
import ReadiumNavigator
@testable import Kios

@Suite("resolveReaderTheme")
struct ReaderThemeResolutionTests {
    @Test(".light always resolves to Readium .light")
    func explicitLight() {
        #expect(resolveReaderTheme(appearance: .light, colorScheme: .light) == .light)
        #expect(resolveReaderTheme(appearance: .light, colorScheme: .dark) == .light)
    }

    @Test(".dark always resolves to Readium .dark")
    func explicitDark() {
        #expect(resolveReaderTheme(appearance: .dark, colorScheme: .light) == .dark)
        #expect(resolveReaderTheme(appearance: .dark, colorScheme: .dark) == .dark)
    }

    @Test(".system follows the SwiftUI colorScheme")
    func systemFollows() {
        #expect(resolveReaderTheme(appearance: .system, colorScheme: .light) == .light)
        #expect(resolveReaderTheme(appearance: .system, colorScheme: .dark) == .dark)
    }
}
