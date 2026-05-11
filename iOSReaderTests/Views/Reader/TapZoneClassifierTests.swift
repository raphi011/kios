import Testing
import CoreGraphics
@testable import iOSReader

@Suite("TapZoneClassifier")
struct TapZoneClassifierTests {

    @Test func classifiesLeftEdge() {
        #expect(TapZoneClassifier.classify(x: 0, width: 400) == .left)
        #expect(TapZoneClassifier.classify(x: 99, width: 400) == .left)
    }

    @Test func classifiesRightEdge() {
        #expect(TapZoneClassifier.classify(x: 301, width: 400) == .right)
        #expect(TapZoneClassifier.classify(x: 400, width: 400) == .right)
    }

    @Test func classifiesCenter() {
        #expect(TapZoneClassifier.classify(x: 100, width: 400) == .center)
        #expect(TapZoneClassifier.classify(x: 200, width: 400) == .center)
        #expect(TapZoneClassifier.classify(x: 300, width: 400) == .center)
    }

    @Test func handlesZeroWidth() {
        #expect(TapZoneClassifier.classify(x: 0, width: 0) == .center)
    }
}
