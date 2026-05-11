import Testing
import Foundation
import SwiftData
import UIKit
@testable import iOSReader
@testable import Core

@MainActor
@Suite("Sign Out")
struct SignOutTests {

    @Test func deletesCatalogOnlyBookRowsAndClearsCaches() throws {
        let container = try ModelContainer(
            for: Book.self, ReadingProgress.self, Download.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let ctx = ModelContext(container)

        let downloaded = Book(
            serverID: "downloaded",
            title: "Downloaded",
            authors: ["A"],
            opdsHref: URL(string: "https://e/a")!,
            acquisitionURL: URL(string: "https://e/a")!,
            format: .epub,
            fileURL: URL(fileURLWithPath: "/tmp/x.epub")
        )
        let catalogOnly = Book(
            serverID: "catalog-only",
            title: "Catalog only",
            authors: ["B"],
            opdsHref: URL(string: "https://e/b")!,
            acquisitionURL: URL(string: "https://e/b")!,
            format: .epub
        )
        ctx.insert(downloaded)
        ctx.insert(catalogOnly)
        try ctx.save()

        // Prime image cache so we can assert it is wiped.
        ImageMemoryCache.shared.store(UIImage(systemName: "book")!,
                                       for: URL(string: "https://e/cover")!)

        AppEnvironment.performSignOut(context: ctx)

        let remaining = try ctx.fetch(FetchDescriptor<Book>())
        #expect(remaining.count == 1)
        #expect(remaining.first?.serverID == "downloaded")
        #expect(ImageMemoryCache.shared.image(
            for: URL(string: "https://e/cover")!) == nil)
    }
}
