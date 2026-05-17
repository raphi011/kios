/// Why a locator change happened, plumbed from `ReaderView` into
/// `ReadingStatsService.sessionDidAdvance`. Drives three policies:
///
///   - `isLinear`              → may credit the per-book furthest-linear watermark
///   - `triggersJumpPill`      → publishes a `JumpReturnTarget` for the recovery pill
///   - `bumpsWatermarkOnResume`→ trusts sync/resume positions as legit reading on
///                                another device, jumping the watermark forward.
///
/// `.programmaticReturn` is a sink case for the pill's own back-jump: it
/// participates in none of the three policies, preventing the back-jump from
/// re-spawning the pill or re-crediting pages.
enum AdvanceSource: String, Sendable, Codable {
    case swipe
    case tap
    case scrubCommit
    case tocJump
    case resumeFromSync
    case programmaticReturn

    var isLinear: Bool { self == .swipe || self == .tap }

    var triggersJumpPill: Bool {
        switch self {
        case .scrubCommit, .tocJump: true
        case .swipe, .tap, .resumeFromSync, .programmaticReturn: false
        }
    }

    var bumpsWatermarkOnResume: Bool { self == .resumeFromSync }
}
