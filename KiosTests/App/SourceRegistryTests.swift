import Testing
import Foundation
import SwiftData
import Core
@testable import Kios

@MainActor
@Suite("SourceRegistry")
struct SourceRegistryTests {

    /// Real AuthStore wired to an isolated UserDefaults suite + a real
    /// KeychainStore. Tests delete entries up-front so they're hermetic.
    private static func makeRegistry(
        context: ModelContext,
        defaults: UserDefaults
    ) -> SourceRegistry {
        let keychain = KeychainStore(service: "com.raphi011.kios.tests.\(UUID().uuidString)")
        let auth = AuthStore(keychain: keychain, defaults: defaults)
        return SourceRegistry(
            modelContext: context,
            authStore: auth,
            deviceID: "test-device",
            deviceName: "Test Device",
            spanResolver: KEPUBSpanResolver()
        )
    }

    private static func makeContext() throws -> ModelContext {
        let container = try ModelContainer.kiosInMemory()
        return ModelContext(container)
    }

    @Test func startsWithEmptyContexts() throws {
        let ctx = try Self.makeContext()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let registry = Self.makeRegistry(context: ctx, defaults: defaults)
        #expect(registry.contexts.isEmpty)
        #expect(registry.context(for: UUID()) == nil)
    }

    @Test("makeContext for a local source builds and caches a SourceContext")
    func makeContextForLocal() throws {
        let ctx = try Self.makeContext()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let registry = Self.makeRegistry(context: ctx, defaults: defaults)
        let local = testSource(kind: .local, into: ctx)

        let sourceCtx = try registry.makeContext(for: local)

        #expect(registry.contexts.count == 1)
        #expect(registry.context(for: local.id) === sourceCtx)
        // Local sources have no sync and no downloads.
        #expect(sourceCtx.sync == nil)
        #expect(sourceCtx.downloads == nil)
    }

    @Test("makeContext is idempotent — same source returns the cached instance")
    func makeContextCaches() throws {
        let ctx = try Self.makeContext()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let registry = Self.makeRegistry(context: ctx, defaults: defaults)
        let local = testSource(kind: .local, into: ctx)

        let first = try registry.makeContext(for: local)
        let second = try registry.makeContext(for: local)

        #expect(first === second)
        #expect(registry.contexts.count == 1)
    }

    @Test("tearDown removes a source's runtime context")
    func tearDownRemoves() throws {
        let ctx = try Self.makeContext()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let registry = Self.makeRegistry(context: ctx, defaults: defaults)
        let local = testSource(kind: .local, into: ctx)
        _ = try registry.makeContext(for: local)
        #expect(registry.contexts.count == 1)

        registry.tearDown(sourceID: local.id)

        #expect(registry.contexts.isEmpty)
        #expect(registry.context(for: local.id) == nil)
    }

    @Test("tearDown is a no-op for unknown sourceIDs")
    func tearDownUnknownIsNoOp() throws {
        let ctx = try Self.makeContext()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let registry = Self.makeRegistry(context: ctx, defaults: defaults)
        // Should not crash, should not throw.
        registry.tearDown(sourceID: UUID())
        #expect(registry.contexts.isEmpty)
    }

    @Test("makeContext for a kosync source without credentials throws")
    func makeContextThrowsWhenCredentialsMissing() throws {
        let ctx = try Self.makeContext()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let registry = Self.makeRegistry(context: ctx, defaults: defaults)
        let kosync = testSource(
            kind: .kosync,
            displayName: "Server",
            serverURL: URL(string: "https://example.com")!,
            into: ctx
        )

        #expect(throws: BackendFactoryError.missingCredentials(.kosync)) {
            _ = try registry.makeContext(for: kosync)
        }
        #expect(registry.contexts.isEmpty)
    }
}
