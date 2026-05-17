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

    // MARK: - Source-keyed API

    @Test func authStoreSaveLoadKosyncBySource() throws {
        let store = makeStore()
        let id = UUID()

        try store.save(
            sourceID: id,
            credentials: ServerCredentials(
                serverURL: URL(string: "https://cwa.example/")!,
                basic: BasicCredentials(username: "alice", password: "hunter2")
            )
        )

        let loaded = try store.load(sourceID: id)
        #expect(loaded?.serverURL.absoluteString == "https://cwa.example/")
        #expect(loaded?.basic.username == "alice")
        #expect(loaded?.basic.password == "hunter2")

        try store.purge(sourceID: id)
    }

    @Test func authStoreSaveLoadKoboBySource() throws {
        let store = makeStore()
        let id = UUID()

        try store.save(
            sourceID: id,
            kobo: KoboCredentials(
                baseURL: URL(string: "https://cwa.example/kobo/SECRET/")!,
                imageURLTemplate: "https://cdn.example/{ImageId}"
            )
        )

        let loaded = try store.loadKobo(sourceID: id)
        #expect(loaded?.baseURL.absoluteString == "https://cwa.example/kobo/SECRET/")
        #expect(loaded?.imageURLTemplate == "https://cdn.example/{ImageId}")

        try store.purge(sourceID: id)
    }

    @Test func authStoreSaveLoadOAuthBySource() throws {
        let store = makeStore()
        let id = UUID()
        let expiry = Date(timeIntervalSince1970: 9_999_999)

        try store.save(
            sourceID: id,
            oauth: OAuthCredentials(
                provider: "google.drive",
                accessToken: "access-abc",
                refreshToken: "refresh-xyz",
                expiresAt: expiry
            )
        )

        let loaded = try store.loadOAuth(sourceID: id)
        #expect(loaded?.provider == "google.drive")
        #expect(loaded?.accessToken == "access-abc")
        #expect(loaded?.refreshToken == "refresh-xyz")
        #expect(loaded?.expiresAt == expiry)

        try store.purge(sourceID: id)
    }

    @Test func authStoreOAuthWithOptionalFieldsNil() throws {
        let store = makeStore()
        let id = UUID()

        try store.save(
            sourceID: id,
            oauth: OAuthCredentials(
                provider: "dropbox",
                accessToken: "access-only"
            )
        )

        let loaded = try store.loadOAuth(sourceID: id)
        #expect(loaded?.provider == "dropbox")
        #expect(loaded?.accessToken == "access-only")
        #expect(loaded?.refreshToken == nil)
        #expect(loaded?.expiresAt == nil)

        try store.purge(sourceID: id)
    }

    @Test func authStorePurgeRemovesAllThreeKinds() throws {
        let store = makeStore()
        let id = UUID()

        try store.save(
            sourceID: id,
            credentials: ServerCredentials(
                serverURL: URL(string: "https://cwa.example/")!,
                basic: BasicCredentials(username: "u", password: "p")
            )
        )
        try store.save(
            sourceID: id,
            kobo: KoboCredentials(
                baseURL: URL(string: "https://cwa.example/kobo/T/")!,
                imageURLTemplate: "https://cdn.example/tmpl"
            )
        )
        try store.save(
            sourceID: id,
            oauth: OAuthCredentials(
                provider: "google.drive",
                accessToken: "access-abc"
            )
        )

        try store.purge(sourceID: id)

        #expect(try store.load(sourceID: id) == nil)
        #expect(try store.loadKobo(sourceID: id) == nil)
        #expect(try store.loadOAuth(sourceID: id) == nil)
    }

    @Test func authStoreIsolatedBySource() throws {
        let store = makeStore()
        let idA = UUID()
        let idB = UUID()

        try store.save(
            sourceID: idA,
            credentials: ServerCredentials(
                serverURL: URL(string: "https://a.example/")!,
                basic: BasicCredentials(username: "alice", password: "pa")
            )
        )
        try store.save(
            sourceID: idB,
            credentials: ServerCredentials(
                serverURL: URL(string: "https://b.example/")!,
                basic: BasicCredentials(username: "bob", password: "pb")
            )
        )

        let a = try store.load(sourceID: idA)
        let b = try store.load(sourceID: idB)

        #expect(a?.serverURL.absoluteString == "https://a.example/")
        #expect(b?.serverURL.absoluteString == "https://b.example/")
        #expect(a?.basic.username == "alice")
        #expect(b?.basic.username == "bob")

        try store.purge(sourceID: idA)
        try store.purge(sourceID: idB)
    }
}
