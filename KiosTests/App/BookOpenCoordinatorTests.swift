import Testing
import Foundation
@testable import Kios

@MainActor
@Suite("BookOpenCoordinator")
struct BookOpenCoordinatorTests {
    @Test func requestSetsPendingID() {
        let c = BookOpenCoordinator()
        let id = UUID()
        c.request(id)
        #expect(c.pendingBookID == id)
    }

    @Test func consumeReturnsAndClears() {
        let c = BookOpenCoordinator()
        let id = UUID()
        c.request(id)
        #expect(c.consume() == id)
        #expect(c.pendingBookID == nil)
    }

    @Test func consumeOnEmptyReturnsNil() {
        let c = BookOpenCoordinator()
        #expect(c.consume() == nil)
        #expect(c.pendingBookID == nil)
    }

    @Test func secondConsumeReturnsNil() {
        let c = BookOpenCoordinator()
        c.request(UUID())
        _ = c.consume()
        #expect(c.consume() == nil)
    }
}
