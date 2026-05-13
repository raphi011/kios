import Testing
import Foundation
import SwiftData
import Core
@testable import Kios

@Suite("DownloadService")
@MainActor
struct DownloadServiceTests {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Book.self, Download.self, ReadingProgress.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    @Test func createsBooksDirectoryOnInit() throws {
        _ = DownloadService(
            context: try makeContext(),
            credentials: .init(username: "u", password: "p")
        )

        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: AppPaths.booksDirectory.path, isDirectory: &isDir)
        #expect(exists)
        #expect(isDir.boolValue)
    }

    @Test func initWithExistingDirectoryDoesNotFail() throws {
        // Should not throw / crash when the directory already exists.
        _ = DownloadService(
            context: try makeContext(),
            credentials: .init(username: "u", password: "p")
        )
    }

    @Test func initWithNilCredentials() throws {
        // Kobo mode: DownloadService is constructed with no credentials and
        // must not crash. The books directory still needs to be created.
        _ = DownloadService(
            context: try makeContext(),
            credentials: nil
        )

        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: AppPaths.booksDirectory.path, isDirectory: &isDir)
        #expect(exists)
        #expect(isDir.boolValue)
    }

    @Test func updatesCredentials() throws {
        let service = DownloadService(
            context: try makeContext(),
            credentials: .init(username: "u1", password: "p1")
        )
        // Just exercise the method — this is a smoke test guarding against
        // future signature changes. The actual auth-header round-trip is
        // covered by HTTPClient tests.
        service.update(credentials: .init(username: "u2", password: "p2"))
    }

    @Test func updatesCredentialsToNil() throws {
        // Switching from kosync (Basic-auth) to Kobo (no auth) without
        // recreating the service should be a no-throw smoke.
        let service = DownloadService(
            context: try makeContext(),
            credentials: .init(username: "u", password: "p")
        )
        service.update(credentials: nil)
    }

    @Test func updatesCredentialsFromNil() throws {
        // Inverse of the above — switching from Kobo back to kosync.
        let service = DownloadService(
            context: try makeContext(),
            credentials: nil
        )
        service.update(credentials: .init(username: "u", password: "p"))
    }
}
