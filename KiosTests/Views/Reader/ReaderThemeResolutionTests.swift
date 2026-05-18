import Testing
import SwiftUI
import ReadiumNavigator
@testable import Kios

@Suite("ReaderThemeResolution.resolve")
struct ReaderThemeResolutionTests {
    @Test(".light always resolves to Readium .light")
    func explicitLight() {
        #expect(ReaderThemeResolution.resolve(appearance: .light, colorScheme: .light) == .light)
        #expect(ReaderThemeResolution.resolve(appearance: .light, colorScheme: .dark) == .light)
    }

    @Test(".dark always resolves to Readium .dark")
    func explicitDark() {
        #expect(ReaderThemeResolution.resolve(appearance: .dark, colorScheme: .light) == .dark)
        #expect(ReaderThemeResolution.resolve(appearance: .dark, colorScheme: .dark) == .dark)
    }

    @Test(".system follows the SwiftUI colorScheme")
    func systemFollows() {
        #expect(ReaderThemeResolution.resolve(appearance: .system, colorScheme: .light) == .light)
        #expect(ReaderThemeResolution.resolve(appearance: .system, colorScheme: .dark) == .dark)
    }
}
