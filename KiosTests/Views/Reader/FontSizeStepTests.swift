import Testing
import CoreGraphics
@testable import Kios

@Suite("FontSizeStep")
struct FontSizeStepTests {

    @Test func identityWhenScaleIsOne() {
        #expect(FontSizeStep.clamp(startPct: 100, scale: 1.0) == 100)
        #expect(FontSizeStep.clamp(startPct: 130, scale: 1.0) == 130)
    }

    @Test func stepsUpInTensOnScaleAbove() {
        // 100 × 1.15 = 115 → rounds to 120 (nearest 10).
        #expect(FontSizeStep.clamp(startPct: 100, scale: 1.15) == 120)
        // 100 × 1.05 = 105 → rounds to 110.
        #expect(FontSizeStep.clamp(startPct: 100, scale: 1.05) == 110)
    }

    @Test func stepsDownInTensOnScaleBelow() {
        // 100 × 0.85 = 85 → rounds to 90.
        #expect(FontSizeStep.clamp(startPct: 100, scale: 0.85) == 90)
    }

    @Test func clampsToMin() {
        // 100 × 0.1 = 10 → clamps to 60.
        #expect(FontSizeStep.clamp(startPct: 100, scale: 0.1) == 60)
        #expect(FontSizeStep.clamp(startPct: 60, scale: 0.5) == 60)
    }

    @Test func clampsToMax() {
        // 100 × 5 = 500 → clamps to 200.
        #expect(FontSizeStep.clamp(startPct: 100, scale: 5.0) == 200)
        #expect(FontSizeStep.clamp(startPct: 200, scale: 1.5) == 200)
    }

    @Test func roundsAtHalfStepBoundary() {
        // 100 × 1.05 = 105 → exactly halfway between 100 and 110.
        #expect(FontSizeStep.clamp(startPct: 100, scale: 1.05) == 110)
    }
}
