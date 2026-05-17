import Foundation

/// Shared mapping between Readium's percent-based
/// `EPUBPreferences.fontSize` (stored in `@AppStorage("reader.fontSizePct")`
/// and stepped by pinch via `FontSizeStep`) and the user-facing point
/// size shown in the reader HUD and Settings stepper.
///
/// 16pt = 100% is a convention, not a measured fact — the actual rendered
/// size still depends on each EPUB's CSS. The conversion just gives users
/// a number that feels like type ("18pt") instead of a multiplier ("112%").
///
/// Percent is intentionally the storage unit:
/// - Readium consumes a multiplier directly (`fontSize: Double`).
/// - `FontSizeStep` defines the canonical 10%-grained grid that pinch
///   snaps onto. Stepping in pt would land on percents that pinch can't
///   reach, so the two entry points would drift.
enum ReaderFontSize {
    /// 100% maps to this point size in the UI.
    static let baseline: Double = 16

    static func pt(forPct pct: Int) -> Int {
        Int((Double(pct) / 100.0 * baseline).rounded())
    }
}
