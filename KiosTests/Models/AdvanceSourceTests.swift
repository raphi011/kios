import Testing
@testable import Kios

@Suite("AdvanceSource")
struct AdvanceSourceTests {
    @Test("swipe and tap are linear sources")
    func linearSources() {
        #expect(AdvanceSource.swipe.isLinear)
        #expect(AdvanceSource.tap.isLinear)
    }

    @Test("nav sources are not linear")
    func nonLinearSources() {
        #expect(!AdvanceSource.scrubCommit.isLinear)
        #expect(!AdvanceSource.tocJump.isLinear)
        #expect(!AdvanceSource.aiQuoteJump.isLinear)
        #expect(!AdvanceSource.resumeFromSync.isLinear)
        #expect(!AdvanceSource.programmaticReturn.isLinear)
    }

    @Test("only scrubCommit/tocJump/aiQuoteJump trigger the pill")
    func pillTriggers() {
        #expect(AdvanceSource.scrubCommit.triggersJumpPill)
        #expect(AdvanceSource.tocJump.triggersJumpPill)
        #expect(AdvanceSource.aiQuoteJump.triggersJumpPill)
        #expect(!AdvanceSource.swipe.triggersJumpPill)
        #expect(!AdvanceSource.tap.triggersJumpPill)
        #expect(!AdvanceSource.resumeFromSync.triggersJumpPill)
        #expect(!AdvanceSource.programmaticReturn.triggersJumpPill)
    }

    @Test("only resumeFromSync bumps the watermark on resume")
    func resumeBump() {
        #expect(AdvanceSource.resumeFromSync.bumpsWatermarkOnResume)
        for source in [AdvanceSource.swipe, .tap, .scrubCommit, .tocJump, .aiQuoteJump, .programmaticReturn] {
            #expect(!source.bumpsWatermarkOnResume)
        }
    }

    @Test("rawValue round-trips for every case")
    func rawValueRoundTrip() {
        let cases: [AdvanceSource] = [
            .swipe, .tap, .scrubCommit, .tocJump,
            .aiQuoteJump, .resumeFromSync, .programmaticReturn
        ]
        for source in cases {
            #expect(AdvanceSource(rawValue: source.rawValue) == source)
        }
        #expect(AdvanceSource(rawValue: "nonexistent") == nil)
    }
}
