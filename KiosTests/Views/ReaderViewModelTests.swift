import Testing
import Foundation
import ReadiumShared
@testable import Kios

@MainActor
@Suite("ReaderViewModel: pure helpers")
struct ReaderViewModelPureHelperTests {

    // MARK: - romanNumeral

    @Test(
        "romanNumeral converts canonical numbers",
        arguments: [
            (1, "I"), (4, "IV"), (5, "V"), (9, "IX"), (10, "X"),
            (40, "XL"), (49, "XLIX"), (50, "L"), (90, "XC"),
            (400, "CD"), (500, "D"), (900, "CM"), (1000, "M"),
            (1994, "MCMXCIV"), (3999, "MMMCMXCIX"),
        ]
    )
    func romanNumeralBasic(input: Int, expected: String) {
        #expect(ReaderViewModel.romanNumeral(input) == expected)
    }

    @Test("romanNumeral returns the arabic numeral for out-of-range inputs")
    func romanNumeralFallback() {
        #expect(ReaderViewModel.romanNumeral(0) == "0")
        #expect(ReaderViewModel.romanNumeral(-3) == "-3")
        #expect(ReaderViewModel.romanNumeral(4000) == "4000")
        #expect(ReaderViewModel.romanNumeral(99999) == "99999")
    }

    // MARK: - parseHref / parseLocator

    @Test func parseHrefExtractsHrefFromLocatorJSON() {
        let json = #"{"href":"chapter1.xhtml","locations":{"progression":0.5}}"#
        #expect(ReaderViewModel.parseHref(json) == "chapter1.xhtml")
    }

    @Test func parseHrefReturnsNilForMissingHref() {
        let json = #"{"locations":{"progression":0.5}}"#
        #expect(ReaderViewModel.parseHref(json) == nil)
    }

    @Test func parseHrefReturnsNilForMalformedJSON() {
        #expect(ReaderViewModel.parseHref("not json") == nil)
        #expect(ReaderViewModel.parseHref(nil) == nil)
    }

    @Test func parseLocatorRoundTrips() throws {
        let json = #"{"href":"ch1.xhtml","type":"text/html","locations":{"progression":0.5,"totalProgression":0.25}}"#
        let locator = try #require(ReaderViewModel.parseLocator(json))
        #expect(locator.href.string == "ch1.xhtml")
        #expect(locator.locations.progression == 0.5)
        #expect(locator.locations.totalProgression == 0.25)
    }

    @Test func parseLocatorReturnsNilForMalformedJSON() {
        #expect(ReaderViewModel.parseLocator(nil) == nil)
        #expect(ReaderViewModel.parseLocator("not json") == nil)
    }
}

@MainActor
@Suite("ReaderViewModel: chapter lookups")
struct ReaderViewModelChapterLookupTests {

    /// Populates a VM with a synthetic TOC for testing chapter resolution.
    /// Three chapters at progressions 0.0, 0.3, 0.6 — matches the shape of
    /// `buildTOCProgressions` output without going through publication parse.
    private func vmWithTOC() -> ReaderViewModel {
        let vm = ReaderViewModel()
        vm.tocProgressions = [
            (progression: 0.0, title: "Chapter 1", depth: 0),
            (progression: 0.3, title: "Chapter 2", depth: 0),
            (progression: 0.6, title: "Chapter 3", depth: 0),
        ]
        return vm
    }

    // MARK: - chapterIndex(at:)

    @Test func chapterIndexReturnsNilForProgressionBeforeFirstEntry() {
        let vm = ReaderViewModel()
        // Empty TOC.
        #expect(vm.chapterIndex(at: 0.5) == nil)
    }

    @Test func chapterIndexReturns1BasedIndex() {
        let vm = vmWithTOC()
        #expect(vm.chapterIndex(at: 0.0) == 1)
        #expect(vm.chapterIndex(at: 0.15) == 1)
        #expect(vm.chapterIndex(at: 0.3) == 2)
        #expect(vm.chapterIndex(at: 0.45) == 2)
        #expect(vm.chapterIndex(at: 0.6) == 3)
        #expect(vm.chapterIndex(at: 0.99) == 3)
    }

    // MARK: - chapterTitle(at:)

    @Test func chapterTitleReturnsEmDashWhenTOCIsEmpty() {
        let vm = ReaderViewModel()
        #expect(vm.chapterTitle(at: 0.5) == "—")
    }

    @Test func chapterTitleReturnsCurrentChapterTitle() {
        let vm = vmWithTOC()
        #expect(vm.chapterTitle(at: 0.0) == "Chapter 1")
        #expect(vm.chapterTitle(at: 0.45) == "Chapter 2")
        #expect(vm.chapterTitle(at: 0.99) == "Chapter 3")
    }

    // MARK: - chapterContext(at:)

    @Test func chapterContextAtFirstChapterHasNilPreviousSlots() {
        let vm = vmWithTOC()
        let ctx = vm.chapterContext(at: 0.0)
        #expect(ctx.previous2 == nil)
        #expect(ctx.previous1 == nil)
        #expect(ctx.current == "Chapter 1")
        #expect(ctx.next1 == "Chapter 2")
        #expect(ctx.next2 == "Chapter 3")
    }

    @Test func chapterContextAtMiddleChapterHasOnePreviousSlot() {
        let vm = vmWithTOC()
        let ctx = vm.chapterContext(at: 0.4)
        #expect(ctx.previous2 == nil)
        #expect(ctx.previous1 == "Chapter 1")
        #expect(ctx.current == "Chapter 2")
        #expect(ctx.next1 == "Chapter 3")
        #expect(ctx.next2 == nil)
    }

    @Test func chapterContextAtLastChapterHasNilNextSlots() {
        let vm = vmWithTOC()
        let ctx = vm.chapterContext(at: 0.99)
        #expect(ctx.previous2 == "Chapter 1")
        #expect(ctx.previous1 == "Chapter 2")
        #expect(ctx.current == "Chapter 3")
        #expect(ctx.next1 == nil)
        #expect(ctx.next2 == nil)
    }

    // MARK: - chapterTitle(forHref:)

    @Test func chapterTitleForHrefMatchesExactResourcePath() {
        let vm = ReaderViewModel()
        vm.tocTitlesByHref = ["ch1.xhtml": "Chapter 1", "ch2.xhtml": "Chapter 2"]
        #expect(vm.chapterTitle(forHref: "ch1.xhtml") == "Chapter 1")
        #expect(vm.chapterTitle(forHref: "ch2.xhtml") == "Chapter 2")
    }

    @Test("chapterTitle(forHref:) strips the anchor before lookup")
    func chapterTitleForHrefStripsAnchor() {
        let vm = ReaderViewModel()
        vm.tocTitlesByHref = ["ch1.xhtml": "Chapter 1"]
        #expect(vm.chapterTitle(forHref: "ch1.xhtml#section-2") == "Chapter 1")
    }

    @Test("chapterTitle(forHref:) falls back to suffix matching")
    func chapterTitleForHrefSuffixMatch() {
        // TOC stored as "OEBPS/ch1.xhtml"; locator href is "ch1.xhtml" (relative)
        let vm = ReaderViewModel()
        vm.tocTitlesByHref = ["OEBPS/ch1.xhtml": "Chapter 1"]
        #expect(vm.chapterTitle(forHref: "ch1.xhtml") == "Chapter 1")
    }

    @Test func chapterTitleForHrefReturnsNilWhenNoMatch() {
        let vm = ReaderViewModel()
        vm.tocTitlesByHref = ["ch1.xhtml": "Chapter 1"]
        #expect(vm.chapterTitle(forHref: "unknown.xhtml") == nil)
        #expect(vm.chapterTitle(forHref: nil) == nil)
    }
}

@MainActor
@Suite("ReaderViewModel: locator change state machine")
struct ReaderViewModelLocatorChangeTests {

    private func locator(href: String = "ch1.xhtml", progression: Double = 0.5) -> Locator {
        let json = """
        {"href":"\(href)","type":"text/html","locations":{"progression":\(progression),"totalProgression":\(progression)}}
        """
        return ReaderViewModel.parseLocator(json)!
    }

    @Test("the first emission is consumed as the load artifact and returns nil")
    func initialEmissionIsArtifact() {
        let vm = ReaderViewModel()
        #expect(vm.consumeLocatorChange(locator()) == nil)
        #expect(vm.initialEmissionSeen)
        #expect(!vm.userHasNavigated)
    }

    @Test("the second emission marks the user as having navigated")
    func secondEmissionMarksNavigated() {
        let vm = ReaderViewModel()
        _ = vm.consumeLocatorChange(locator())   // initial artifact
        let outcome = vm.consumeLocatorChange(locator(progression: 0.6))
        #expect(outcome != nil)
        #expect(vm.userHasNavigated)
    }

    @Test("subsequent emission carries the locator JSON + progression")
    func subsequentEmissionPayload() throws {
        let vm = ReaderViewModel()
        _ = vm.consumeLocatorChange(locator())
        let outcome = try #require(vm.consumeLocatorChange(locator(progression: 0.6)))
        #expect(outcome.totalProgression == 0.6)
        #expect(outcome.advanceSource == .swipe)   // default when pendingJumpSource is nil
        #expect(!outcome.didCrossForwardChapter)   // no TOC populated -> no crossing
    }

    @Test("pendingJumpSource is consumed on each emission")
    func pendingJumpSourceIsConsumed() throws {
        let vm = ReaderViewModel()
        _ = vm.consumeLocatorChange(locator())
        vm.pendingJumpSource = .tocJump
        let outcome = try #require(vm.consumeLocatorChange(locator(progression: 0.7)))
        #expect(outcome.advanceSource == .tocJump)
        #expect(vm.pendingJumpSource == nil)
    }
}

@MainActor
@Suite("ReaderViewModel: scrub state machine")
struct ReaderViewModelScrubTests {

    @Test func setScrubProgressClearsCommitPendingAndStoresProgress() {
        let vm = ReaderViewModel()
        vm.scrubCommitPending = true
        vm.setScrubProgress(0.42)
        #expect(vm.scrubProgress == 0.42)
        #expect(!vm.scrubCommitPending)
    }

    @Test func cancelScrubClearsBothFields() {
        let vm = ReaderViewModel()
        vm.scrubProgress = 0.5
        vm.scrubCommitPending = true
        vm.cancelScrub()
        #expect(vm.scrubProgress == nil)
        #expect(!vm.scrubCommitPending)
    }

    @Test("commitScrub is a no-op when positions are not loaded")
    func commitScrubNoOpWithoutPositions() {
        let vm = ReaderViewModel()
        vm.scrubProgress = 0.5
        vm.commitScrub(to: 0.7)
        #expect(vm.scrubProgress == nil)
        #expect(vm.pendingJump == nil)
    }

    @Test("navigatorCaughtUpDuringScrub clears the post-commit hold")
    func navigatorCaughtUpClearsHold() {
        let vm = ReaderViewModel()
        vm.scrubProgress = 0.5
        vm.scrubCommitPending = true
        vm.navigatorCaughtUpDuringScrub()
        #expect(vm.scrubCommitPending == false)
        #expect(vm.scrubProgress == nil)
    }

    @Test("navigatorCaughtUpDuringScrub is a no-op when no commit is pending")
    func navigatorCaughtUpNoOpWhenNoCommit() {
        let vm = ReaderViewModel()
        vm.scrubProgress = 0.5         // active drag, no commit yet
        vm.navigatorCaughtUpDuringScrub()
        // scrubProgress should NOT be cleared — that's an in-progress drag.
        #expect(vm.scrubProgress == 0.5)
    }
}
