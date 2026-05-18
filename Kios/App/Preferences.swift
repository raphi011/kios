import SwiftUI

/// Typed wrapper around an `@AppStorage` key + default value. Lets views
/// declare a preference in one place and reference it as `@AppStorage(.foo)`
/// so a typo in one call site can't silently break behaviour.
///
/// Usage:
///
/// ```
/// @AppStorage(.readerFontSizePct) private var fontSizePct: Int
/// ```
///
/// `AppStorage` initialises with the preference's default the first time the
/// key is touched on disk.
struct Preference<Value> {
    let key: String
    let defaultValue: Value
}

// MARK: - Reader

extension Preference where Value == Int {
    static let readerFontSizePct = Preference(key: "reader.fontSizePct", defaultValue: 100)
}

extension Preference where Value == String {
    /// Empty string = publisher default (no `EPUBPreferences.fontFamily`
    /// override); non-empty = CSS family name passed to Readium verbatim.
    static let readerFontFamily = Preference(key: "reader.fontFamily", defaultValue: "")
}

extension Preference where Value == Bool {
    /// On by default. Plays a subtle haptic when a normal swipe/tap crosses
    /// into a new chapter. Silent for TOC jumps, scrubs, and sync-resume —
    /// the toggle gates only linear chapter transitions.
    static let readerHapticChapterEnabled = Preference(
        key: "reader.hapticChapterEnabled", defaultValue: true
    )
}

// MARK: - Library

extension Preference where Value == Bool {
    static let libraryGalleryMode = Preference(key: "library.galleryMode", defaultValue: false)
}

// MARK: - AppStorage convenience inits

extension AppStorage where Value == Int {
    init(_ pref: Preference<Int>) {
        self.init(wrappedValue: pref.defaultValue, pref.key)
    }
}

extension AppStorage where Value == String {
    init(_ pref: Preference<String>) {
        self.init(wrappedValue: pref.defaultValue, pref.key)
    }
}

extension AppStorage where Value == Bool {
    init(_ pref: Preference<Bool>) {
        self.init(wrappedValue: pref.defaultValue, pref.key)
    }
}
