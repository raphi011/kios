import Testing
import Foundation
import Core
@testable import Kios

@Suite("BackendFactory", .serialized)
struct BackendFactoryTests {

    /// Unique per-test UserDefaults suite + KeychainStore service so tests
    /// can't pollute each other through the system keychain or shared defaults.
    private func makeStore() -> AuthStore {
        let suiteName = "BackendFactoryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let keychain = KeychainStore(service: "test.\(UUID().uuidString)")
        return AuthStore(keychain: keychain, defaults: defaults)
    }

    @Test func buildsKOSyncWhenActive() throws {
        let store = makeStore()
        defer { try? store.clear() }
        store.saveActiveProtocol(.kosync)
        try store.save(
            serverURL: URL(string: "https://cwa.example/")!,
            username: "alice",
            password: "hunter2"
        )

        let (sync, catalog) = try BackendFactory.build(
            auth: store, deviceID: "D", deviceName: "iPhone"
        )

        #expect(sync is KOSyncBackend)
        #expect(catalog is OPDSCatalogAdapter)
    }

    @Test func buildsKoboWhenActive() throws {
        let store = makeStore()
        defer { try? store.clear() }
        store.saveActiveProtocol(.kobo)
        try store.saveKobo(
            KoboCredentials(
                baseURL: URL(string: "https://cwa.example/kobo/SECRET-TOKEN/")!,
                imageURLTemplate: "https://cdn.example/{ImageId}/{width}/{height}/false/image.jpg"
            )
        )

        let (sync, catalog) = try BackendFactory.build(
            auth: store, deviceID: "D", deviceName: "iPhone"
        )

        #expect(sync is KoboBackend)
        #expect(catalog is KoboBackend)
        // Same actor must back both slots — sharing the imageURLTemplate
        // cache is the whole reason `KoboBackend` fills both roles.
        #expect((sync as AnyObject) === (catalog as AnyObject))
    }

    @Test func throwsWhenKOSyncCredsMissing() throws {
        let store = makeStore()
        store.saveActiveProtocol(.kosync)

        do {
            _ = try BackendFactory.build(auth: store, deviceID: "D", deviceName: "iPhone")
            Issue.record("expected throw")
        } catch let err as BackendFactoryError {
            #expect(err == .missingCredentials(.kosync))
        }
    }

    @Test func throwsWhenKoboCredsMissing() throws {
        let store = makeStore()
        store.saveActiveProtocol(.kobo)

        do {
            _ = try BackendFactory.build(auth: store, deviceID: "D", deviceName: "iPhone")
            Issue.record("expected throw")
        } catch let err as BackendFactoryError {
            #expect(err == .missingCredentials(.kobo))
        }
    }

    @Test func defaultProtocolBuildsKOSync() throws {
        // Fresh store — no saveActiveProtocol call. AuthStore defaults to .kosync,
        // so kosync creds alone are enough.
        let store = makeStore()
        defer { try? store.clear() }
        try store.save(
            serverURL: URL(string: "https://cwa.example/")!,
            username: "alice",
            password: "hunter2"
        )

        let (sync, catalog) = try BackendFactory.build(
            auth: store, deviceID: "D", deviceName: "iPhone"
        )

        #expect(sync is KOSyncBackend)
        #expect(catalog is OPDSCatalogAdapter)
    }
}
