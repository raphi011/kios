import Testing
import Foundation
@testable import Kios

@MainActor
@Suite("ReaderRouter")
struct ReaderRouterTests {

    @Test func startsWithNoActiveReader() {
        let router = ReaderRouter()
        #expect(router.activeReader == nil)
    }

    @Test func openReaderSetsActiveReader() {
        let router = ReaderRouter()
        let id = UUID()
        router.openReader(id)
        #expect(router.activeReader?.id == id)
    }

    @Test("openReader is a no-op when a reader is already open")
    func openReaderIsIdempotentWhileActive() {
        let router = ReaderRouter()
        let first = UUID()
        let second = UUID()
        router.openReader(first)
        router.openReader(second)
        // The second call must NOT yank the user to a different book —
        // a stale intent firing while the user is reading should be ignored.
        #expect(router.activeReader?.id == first)
    }

    @Test("clearing activeReader unblocks a subsequent open")
    func clearingActiveReaderUnblocks() {
        let router = ReaderRouter()
        let first = UUID()
        let second = UUID()
        router.openReader(first)
        router.activeReader = nil
        router.openReader(second)
        #expect(router.activeReader?.id == second)
    }
}
