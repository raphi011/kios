import Testing
@testable import Kios

@Suite("StatsFormatters")
struct StatsFormattersTests {
    @Test func formatsTimeUnderOneHour() {
        #expect(StatsFormatters.time(seconds: 0) == "0m")
        #expect(StatsFormatters.time(seconds: 45 * 60) == "45m")
        #expect(StatsFormatters.time(seconds: 59 * 60 + 59) == "59m")
    }

    @Test func formatsTimeUnderTenHours() {
        #expect(StatsFormatters.time(seconds: 60 * 60) == "1h 0m")
        #expect(StatsFormatters.time(seconds: 9 * 3600 + 30 * 60) == "9h 30m")
        // Boundary check below: exactly 10h → switches to "Nh" form
    }

    @Test func formatsTimeAtAndOverTenHours() {
        #expect(StatsFormatters.time(seconds: 10 * 3600) == "10h")
        #expect(StatsFormatters.time(seconds: 87 * 3600 + 15 * 60) == "87h")
    }

    @Test func formatsCount() {
        #expect(StatsFormatters.count(0) == "0")
        #expect(StatsFormatters.count(12) == "12")
    }

    @Test func formatsPagesWithGrouping() {
        // Grouping separator is locale-dependent in production; assert that
        // digits appear and a separator is inserted at thousands.
        let result = StatsFormatters.pages(4210)
        #expect(result.contains("4"))
        #expect(result.contains("210"))
        #expect(result.count >= 5)        // "4,210" or "4.210" — both 5 chars
    }

    @Test func formatsStreak() {
        #expect(StatsFormatters.streak(days: 0) == "0 d")
        #expect(StatsFormatters.streak(days: 1) == "1 d")
        #expect(StatsFormatters.streak(days: 365) == "365 d")
    }
}
