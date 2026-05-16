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

    func test_apply_system_removesAppleLanguagesKey() {
        defaults.set(["de"], forKey: "AppleLanguages")
        LanguagePreferenceApplier(defaults: defaults).apply(.system)
        XCTAssertNil(defaults.object(forKey: "AppleLanguages"))
    }

    func test_apply_english_writesEnArray() {
        LanguagePreferenceApplier(defaults: defaults).apply(.english)
        XCTAssertEqual(
            defaults.array(forKey: "AppleLanguages") as? [String],
            ["en"]
        )
    }

    func test_apply_german_writesDeArray() {
        LanguagePreferenceApplier(defaults: defaults).apply(.german)
        XCTAssertEqual(
            defaults.array(forKey: "AppleLanguages") as? [String],
            ["de"]
        )
    }

    func test_appleLanguagesValue_isLocaleIndependent() {
        XCTAssertNil(LanguagePreference.system.appleLanguagesValue)
        XCTAssertEqual(LanguagePreference.english.appleLanguagesValue, ["en"])
        XCTAssertEqual(LanguagePreference.german.appleLanguagesValue, ["de"])
    }
}
