import Testing
import SwiftUI
@testable import Kios

@Suite("AppearancePreference")
struct AppearancePreferenceTests {
    @Test("system maps to nil ColorScheme (follow system)")
    func systemFollowsSystem() {
        #expect(AppearancePreference.system.swiftUIScheme == nil)
    }

    @Test("light maps to .light")
    func lightExplicit() {
        #expect(AppearancePreference.light.swiftUIScheme == .light)
    }

    @Test("dark maps to .dark")
    func darkExplicit() {
        #expect(AppearancePreference.dark.swiftUIScheme == .dark)
    }

    @Test("allCases covers system, light, dark")
    func allCases() {
        #expect(AppearancePreference.allCases == [.system, .light, .dark])
    }

    @Test("rawValue is stable for AppStorage persistence")
    func rawValues() {
        #expect(AppearancePreference.system.rawValue == "system")
        #expect(AppearancePreference.light.rawValue == "light")
        #expect(AppearancePreference.dark.rawValue == "dark")
    }
}
