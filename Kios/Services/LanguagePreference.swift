import Foundation

/// User-selectable UI language for Kios.
///
/// `.system` defers to iOS's `AppleLanguages` resolution (i.e. follows the
/// device language). The explicit cases override that resolution by writing
/// the `AppleLanguages` UserDefaults key for this app's sandbox. The
/// override only takes effect after the app is relaunched — iOS reads
/// `AppleLanguages` once at process start to pick the bundle's `.lproj`.
enum LanguagePreference: String, CaseIterable, Identifiable, Sendable {
    case system
    case english
    case german

    var id: String { rawValue }

    /// `nil` means "remove the override and follow system".
    var appleLanguagesValue: [String]? {
        switch self {
        case .system:  nil
        case .english: ["en"]
        case .german:  ["de"]
        }
    }
}

/// Writes the `AppleLanguages` UserDefaults override that iOS reads at next
/// app launch. Injected with the `UserDefaults` it should mutate so tests
/// can use a sandboxed suite.
struct LanguagePreferenceApplier {
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func apply(_ pref: LanguagePreference) {
        if let value = pref.appleLanguagesValue {
            defaults.set(value, forKey: "AppleLanguages")
        } else {
            defaults.removeObject(forKey: "AppleLanguages")
        }
    }
}
