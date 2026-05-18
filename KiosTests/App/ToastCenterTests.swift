import Testing
import Foundation
@testable import Kios

@MainActor
@Suite("ToastCenter")
struct ToastCenterTests {

    @Test func startsEmpty() {
        let center = ToastCenter()
        #expect(center.current == nil)
    }

    @Test("report sets current immediately when nothing else is showing")
    func reportShowsImmediately() {
        let center = ToastCenter()
        center.report("Hello", level: .info)
        #expect(center.current?.message == "Hello")
        #expect(center.current?.level == .info)
    }

    @Test("second report queues behind the first")
    func secondReportQueues() {
        let center = ToastCenter()
        center.report("First", level: .info)
        center.report("Second", level: .error)
        // Current is still First; Second is queued behind.
        #expect(center.current?.message == "First")
    }

    @Test("dismiss advances to the next queued toast")
    func dismissAdvancesQueue() {
        let center = ToastCenter()
        center.report("First", level: .info)
        center.report("Second", level: .error)
        center.dismiss()
        #expect(center.current?.message == "Second")
        #expect(center.current?.level == .error)
    }

    @Test("dismiss with an empty queue clears current")
    func dismissEmptyQueueClears() {
        let center = ToastCenter()
        center.report("Only", level: .warning)
        center.dismiss()
        #expect(center.current == nil)
    }

    @Test("report(error:) uses localizedDescription and .error level")
    func reportErrorUsesLocalizedDescriptionAndErrorLevel() {
        struct StubError: LocalizedError {
            var errorDescription: String? { "Something went wrong" }
        }
        let center = ToastCenter()
        center.report(StubError())
        #expect(center.current?.message == "Something went wrong")
        #expect(center.current?.level == .error)
    }

    @Test("each toast gets a fresh id even if the message repeats")
    func eachToastGetsFreshID() {
        let center = ToastCenter()
        center.report("Same", level: .info)
        let firstID = center.current?.id
        center.dismiss()
        center.report("Same", level: .info)
        let secondID = center.current?.id
        #expect(firstID != secondID)
    }
}
