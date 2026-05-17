import SwiftUI

/// Curated font catalogue offered in Settings → Default font and persisted
/// via `@AppStorage("reader.fontFamily")`. The stored raw value is fed
/// through `ReaderContainerVC` into Readium's `EPUBPreferences.fontFamily`
/// — empty string = "Publisher default" (no CSS override, the EPUB's own
/// typography stands).
///
/// The non-empty raw values match Readium's vetted iOS-bundled family
/// names exactly (see `FontFamily` in `swift-toolkit/Sources/Navigator/
/// Preferences/Types.swift`) so they round-trip through CSS without
/// translation.
enum ReaderFontFamily: String, CaseIterable, Identifiable {
    case publisher = ""
    case iowanOldStyle = "Iowan Old Style"
    case palatino = "Palatino"
    case georgia = "Georgia"
    case athelas = "Athelas"
    case helveticaNeue = "Helvetica Neue"
    case seravek = "Seravek"
    case openDyslexic = "OpenDyslexic"

    var id: String { rawValue }

    /// Display label used in the settings row + picker. `publisher` is the
    /// "no override" sentinel, surfaced as a friendlier label than the
    /// empty rawValue.
    var displayName: String {
        switch self {
        case .publisher:     return "Publisher default"
        case .iowanOldStyle: return "Iowan Old Style"
        case .palatino:      return "Palatino"
        case .georgia:       return "Georgia"
        case .athelas:       return "Athelas"
        case .helveticaNeue: return "Helvetica Neue"
        case .seravek:       return "Seravek"
        case .openDyslexic:  return "OpenDyslexic"
        }
    }

    /// SwiftUI font used to render the name in its own typeface as a live
    /// preview. Falls back to the system serif for `publisher` (no specific
    /// face) and `openDyslexic` (Readium-embedded; not installed for the
    /// host app so `.custom` would silently fall back anyway).
    func previewFont(size: CGFloat) -> Font {
        switch self {
        case .publisher, .openDyslexic:
            return .system(size: size, design: .serif)
        default:
            return .custom(rawValue, size: size)
        }
    }

    /// Resolves a persisted raw value (typically from `@AppStorage`) back
    /// to a catalogue entry. Falls back to `publisher` so a value written
    /// by a future build with an unknown font silently degrades to the
    /// publisher's own styling rather than crashing the reader.
    static func from(rawValue: String) -> ReaderFontFamily {
        ReaderFontFamily(rawValue: rawValue) ?? .publisher
    }
}
