import Testing
import Foundation
@testable import Core

@Suite("KeychainStore")
struct KeychainStoreTests {

    @Test func roundTripsValue() throws {
        let store = KeychainStore(service: "test.\(UUID().uuidString)")
        defer { try? store.delete(account: "user") }

        try store.set("hunter2", account: "user")
        let got = try store.get(account: "user")
        #expect(got == "hunter2")
    }

    @Test func returnsNilForMissingAccount() throws {
        let store = KeychainStore(service: "test.\(UUID().uuidString)")
        let got = try store.get(account: "ghost")
        #expect(got == nil)
    }

    @Test func overwritesExistingValue() throws {
        let store = KeychainStore(service: "test.\(UUID().uuidString)")
        defer { try? store.delete(account: "user") }

        try store.set("first", account: "user")
        try store.set("second", account: "user")
        #expect(try store.get(account: "user") == "second")
    }

    @Test func deleteRemovesValue() throws {
        let store = KeychainStore(service: "test.\(UUID().uuidString)")
        defer { try? store.delete(account: "user") }
        try store.set("x", account: "user")
        try store.delete(account: "user")
        #expect(try store.get(account: "user") == nil)
    }

    @Test func deletingMissingAccountIsNoOp() throws {
        let store = KeychainStore(service: "test.\(UUID().uuidString)")
        // No `set` call — account doesn't exist.
        // Expectation: no throw.
        try store.delete(account: "ghost")
    }
}
