import Testing
import CoreGraphics
@testable import Kios

@Suite("SwipeDismissPolicy")
struct SwipeDismissPolicyTests {

    @Test func dismissesOnLargeDownwardVerticalDrag() {
        let result = SwipeDismissPolicy.shouldDismiss(
            translation: CGSize(width: 10, height: 200),
            velocity: CGSize(width: 0, height: 800)
        )
        #expect(result == true)
    }

    @Test func rejectsShortDrag() {
        let result = SwipeDismissPolicy.shouldDismiss(
            translation: CGSize(width: 0, height: 50),
            velocity: CGSize(width: 0, height: 800)
        )
        #expect(result == false)
    }

    @Test func rejectsUpwardDrag() {
        let result = SwipeDismissPolicy.shouldDismiss(
            translation: CGSize(width: 0, height: -200),
            velocity: CGSize(width: 0, height: -800)
        )
        #expect(result == false)
    }

    @Test func rejectsHorizontalDominantDrag() {
        let result = SwipeDismissPolicy.shouldDismiss(
            translation: CGSize(width: 200, height: 150),
            velocity: CGSize(width: 600, height: 400)
        )
        #expect(result == false)
    }

    @Test func rejectsZeroVelocityEvenIfDistanceMet() {
        let result = SwipeDismissPolicy.shouldDismiss(
            translation: CGSize(width: 0, height: 200),
            velocity: CGSize(width: 0, height: 0)
        )
        #expect(result == false)
    }
}
