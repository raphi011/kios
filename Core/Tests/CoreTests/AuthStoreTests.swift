import Testing
import Foundation
@testable import Core

@Suite("AuthStore", .serialized)
struct AuthStoreTests {

    private func makeStore() -> AuthStore {
        // Unique per test to prevent cross-test pollution.
        let suiteName = "AuthStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let keychain = KeychainStore(service: "test.\(UUID().uuidString)")
        return AuthStore(keychain: keychain, defaults: defaults)
    }

    @Test func loadReturnsNilWhenEmpty() throws {
        let store = makeStore()
        #expect(try store.load() == nil)
    }

    @Test func saveAndLoadRoundTrip() throws {
        let store = makeStore()
        defer { try? store.clear() }

        try store.save(
            serverURL: URL(string: "https://cwa.example/")!,
            username: "alice",
            password: "hunter2"
        )

        let creds = try store.load()
        #expect(creds?.serverURL.absoluteString == "https://cwa.example/")
        #expect(creds?.basic.username == "alice")
        #expect(creds?.basic.password == "hunter2")
    }

    @Test func saveOverwritesExisting() throws {
        let store = makeStore()
        defer { try? store.clear() }

        try store.save(
            serverURL: URL(string: "https://a/")!,
            username: "alice",
            password: "first"
        )
        try store.save(
            serverURL: URL(string: "https://b/")!,
            username: "bob",
            password: "second"
        )

        let creds = try store.load()
        #expect(creds?.serverURL.absoluteString == "https://b/")
        #expect(creds?.basic.username == "bob")
        #expect(creds?.basic.password == "second")
    }

    @Test func clearRemovesAllParts() throws {
        let store = makeStore()
        try store.save(
            serverURL: URL(string: "https://x/")!,
            username: "u",
            password: "p"
        )
        try store.clear()
        #expect(try store.load() == nil)
    }

    @Test func loadReturnsNilWhenPasswordMissing() throws {
        // Build a store, save defaults+keychain, then create a NEW store with the
        // same defaults but a fresh (empty) keychain. Result: defaults still has
        // url+username but keychain has no password → load returns nil.
        let suiteName = "AuthStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let originalKC = KeychainStore(service: "test.\(UUID().uuidString)")
        let original = AuthStore(keychain: originalKC, defaults: defaults)

        try original.save(
            serverURL: URL(string: "https://x/")!,
            username: "u",
            password: "p"
        )
        defer { try? original.clear() }

        // Fresh keychain — empty. Same defaults, so URL+username still present.
        let bareStore = AuthStore(
            keychain: KeychainStore(service: "test.\(UUID().uuidString)"),
            defaults: defaults
        )
        #expect(try bareStore.load() == nil)
    }
}
