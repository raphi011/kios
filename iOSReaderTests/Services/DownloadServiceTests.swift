import Testing
import Foundation
import SwiftData
import Core
@testable import iOSReader

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
}
