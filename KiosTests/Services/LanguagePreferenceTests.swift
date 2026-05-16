import XCTest
@testable import Kios

final class LanguagePreferenceTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "test.lang.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    /// Reads the suite's persistent domain directly. `UserDefaults.object(forKey:)`
    /// walks the full lookup hierarchy (suite → global), so removing `AppleLanguages`
    /// from a suite still surfaces the device's system value. We need to verify
    /// the suite's own storage in isolation.
    private var persistedAppleLanguages: [String]? {
        UserDefaults().persistentDomain(forName: suiteName)?["AppleLanguages"] as? [String]
    }

    func test_apply_system_removesAppleLanguagesKey() {
        defaults.set(["de"], forKey: "AppleLanguages")
        XCTAssertEqual(persistedAppleLanguages, ["de"], "precondition: override is set")

        LanguagePreferenceApplier(defaults: defaults).apply(.system)

        XCTAssertNil(persistedAppleLanguages)
    }

    func test_apply_english_writesEnArray() {
        LanguagePreferenceApplier(defaults: defaults).apply(.english)
        XCTAssertEqual(persistedAppleLanguages, ["en"])
    }

    func test_apply_german_writesDeArray() {
        LanguagePreferenceApplier(defaults: defaults).apply(.german)
        XCTAssertEqual(persistedAppleLanguages, ["de"])
    }

    func test_appleLanguagesValue_isLocaleIndependent() {
        XCTAssertNil(LanguagePreference.system.appleLanguagesValue)
        XCTAssertEqual(LanguagePreference.english.appleLanguagesValue, ["en"])
        XCTAssertEqual(LanguagePreference.german.appleLanguagesValue, ["de"])
    }
}
