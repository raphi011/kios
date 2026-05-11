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

    @Test func activeProtocolDefaultsToKOSync() {
        let store = makeStore()
        #expect(store.loadActiveProtocol() == .kosync)
    }

    @Test func activeProtocolRoundTrip() {
        let store = makeStore()
        defer { try? store.clear() }

        store.saveActiveProtocol(.kobo)
        #expect(store.loadActiveProtocol() == .kobo)
    }

    @Test func loadKoboReturnsNilWhenEmpty() throws {
        let store = makeStore()
        #expect(try store.loadKobo() == nil)
    }

    @Test func saveAndLoadKoboRoundTrip() throws {
        let store = makeStore()
        defer { try? store.clear() }

        try store.saveKobo(
            KoboCredentials(
                baseURL: URL(string: "https://cwa.example/kobo/SECRET-TOKEN/")!,
                imageURLTemplate: "https://cdn.example/{ImageId}/{Width}/{Height}/false/image.jpg"
            )
        )

        let loaded = try store.loadKobo()
        #expect(loaded?.baseURL.absoluteString == "https://cwa.example/kobo/SECRET-TOKEN/")
        #expect(loaded?.imageURLTemplate == "https://cdn.example/{ImageId}/{Width}/{Height}/false/image.jpg")
    }

    @Test func saveAndLoadKoboWithoutImageURLTemplate() throws {
        let store = makeStore()
        defer { try? store.clear() }

        try store.saveKobo(
            KoboCredentials(baseURL: URL(string: "https://cwa.example/kobo/T/")!)
        )

        let loaded = try store.loadKobo()
        #expect(loaded?.baseURL.absoluteString == "https://cwa.example/kobo/T/")
        #expect(loaded?.imageURLTemplate == nil)
    }

    @Test func saveKoboOverwritesImageURLTemplate() throws {
        let store = makeStore()
        defer { try? store.clear() }

        try store.saveKobo(
            KoboCredentials(
                baseURL: URL(string: "https://cwa.example/kobo/T/")!,
                imageURLTemplate: "https://cdn.example/template1"
            )
        )
        try store.saveKobo(
            KoboCredentials(baseURL: URL(string: "https://cwa.example/kobo/T/")!)
        )

        let loaded = try store.loadKobo()
        #expect(loaded?.imageURLTemplate == nil)
    }

    @Test func clearWipesKobo() throws {
        let store = makeStore()

        try store.save(
            serverURL: URL(string: "https://cwa.example/")!,
            username: "alice",
            password: "hunter2"
        )
        store.saveActiveProtocol(.kobo)
        try store.saveKobo(
            KoboCredentials(
                baseURL: URL(string: "https://cwa.example/kobo/T/")!,
                imageURLTemplate: "https://cdn.example/template"
            )
        )

        try store.clear()

        #expect(try store.load() == nil)
        #expect(try store.loadKobo() == nil)
        #expect(store.loadActiveProtocol() == .kosync)
    }

    @Test func clearWipesActiveProtocol() throws {
        let store = makeStore()

        store.saveActiveProtocol(.kobo)
        try store.clear()

        #expect(store.loadActiveProtocol() == .kosync)
    }
}
