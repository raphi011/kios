// KiosTests/Services/AI/AISettingsTests.swift
import Testing
@testable import Kios
import Foundation

@Suite("AISettings")
struct AISettingsTests {
    private func makeSuite() -> UserDefaults {
        let name = "test.ai.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("featuresEnabled defaults to false")
    func featuresDefaultOff() {
        let s = AISettings(defaults: makeSuite())
        #expect(s.featuresEnabled == false)
    }

    @Test("featuresEnabled round-trips")
    func featuresRoundTrip() {
        let defaults = makeSuite()
        let s = AISettings(defaults: defaults)
        s.featuresEnabled = true
        #expect(s.featuresEnabled == true)
        let s2 = AISettings(defaults: defaults)
        #expect(s2.featuresEnabled == true)
    }

    @Test("preferredEngine defaults to gemma4_e4b")
    func preferredDefaultGemma() {
        let s = AISettings(defaults: makeSuite())
        #expect(s.preferredEngine == .gemma4_e4b)
    }

    @Test("preferredEngine round-trips")
    func preferredRoundTrip() {
        let defaults = makeSuite()
        let s = AISettings(defaults: defaults)
        s.preferredEngine = .foundationModels
        #expect(s.preferredEngine == .foundationModels)
        let s2 = AISettings(defaults: defaults)
        #expect(s2.preferredEngine == .foundationModels)
    }

    @Test("allowCellularDownload defaults to false")
    func cellularDefaultOff() {
        let s = AISettings(defaults: makeSuite())
        #expect(s.allowCellularDownload == false)
    }

    @Test("didShowFirstEnableSheet defaults to false")
    func firstEnableDefaultOff() {
        let s = AISettings(defaults: makeSuite())
        #expect(s.didShowFirstEnableSheet == false)
    }
}
