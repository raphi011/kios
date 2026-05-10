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
            for: Book.self, Download.self, ReadingProgress.self, LibraryServer.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    @Test func createsBooksDirectoryOnInit() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        // Pre-condition: directory does not exist.
        #expect(FileManager.default.fileExists(atPath: dir.path) == false)

        _ = DownloadService(
            context: try makeContext(),
            booksDirectory: dir,
            credentials: .init(username: "u", password: "p")
        )

        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir))
        #expect(isDir.boolValue)

        try? FileManager.default.removeItem(at: dir)
    }

    @Test func initWithExistingDirectoryDoesNotFail() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Should not throw / crash.
        _ = DownloadService(
            context: try makeContext(),
            booksDirectory: dir,
            credentials: .init(username: "u", password: "p")
        )
    }
}
