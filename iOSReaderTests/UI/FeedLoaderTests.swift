import Testing
import Foundation
@testable import iOSReader
@testable import Core

@MainActor
@Suite("FeedLoader")
struct FeedLoaderTests {

    @Test func loadFirstPagePopulatesEntries() async {
        let opds = FakeOPDSClient(responses: [
            URL(string: "https://example/opds/")!: .success(.init(
                title: "Root",
                entries: [.navigation(.init(id: "a", title: "A", summary: nil,
                                            href: URL(string: "https://example/a")!))],
                nextURL: nil,
                searchDescriptorURL: nil
            )),
        ])
        let loader = FeedLoader(opds: opds,
                                initialURL: URL(string: "https://example/opds/")!)
        await loader.loadFirstPage()
        #expect(loader.entries.count == 1)
        #expect(loader.title == "Root")
        if case .loaded = loader.phase {} else { Issue.record("expected .loaded") }
    }

    @Test func loadNextPageAppendsEntries() async {
        let url1 = URL(string: "https://example/opds/?offset=0")!
        let url2 = URL(string: "https://example/opds/?offset=60")!
        let pub: (String) -> OPDSFeed.Entry = { id in
            .acquisition(.init(serverID: id, title: id, authors: [],
                               summary: nil, publishedAt: nil,
                               acquisitions: [.init(href: URL(string: "https://e/\(id).epub")!,
                                                    mimeType: "application/epub+zip",
                                                    format: .epub)],
                               thumbnailURL: nil, coverURL: nil))
        }
        let opds = FakeOPDSClient(responses: [
            url1: .success(.init(title: "x", entries: [pub("a"), pub("b")],
                                 nextURL: url2, searchDescriptorURL: nil)),
            url2: .success(.init(title: "x", entries: [pub("c")],
                                 nextURL: nil, searchDescriptorURL: nil)),
        ])
        let loader = FeedLoader(opds: opds, initialURL: url1)
        await loader.loadFirstPage()
        await loader.loadNextPage()
        #expect(loader.entries.map(\.id) == ["a", "b", "c"])
        #expect(loader.nextURL == nil)
    }

    @Test func concurrentLoadNextPageDedupes() async {
        let url1 = URL(string: "https://example/opds/?offset=0")!
        let url2 = URL(string: "https://example/opds/?offset=60")!
        let opds = FakeOPDSClient(responses: [
            url1: .success(.init(title: "x", entries: [],
                                 nextURL: url2, searchDescriptorURL: nil)),
            url2: .delayedSuccess(.init(title: "x", entries: [],
                                        nextURL: nil, searchDescriptorURL: nil),
                                  delayNanoseconds: 100_000_000),
        ])
        let loader = FeedLoader(opds: opds, initialURL: url1)
        await loader.loadFirstPage()
        async let a: () = loader.loadNextPage()
        async let b: () = loader.loadNextPage()
        _ = await (a, b)
        let count = opds.requestCount(for: url2)
        #expect(count == 1)
    }

    @Test func refreshInvalidatesCacheAndReloads() async {
        let url = URL(string: "https://example/opds/")!
        let opds = FakeOPDSClient(responses: [
            url: .success(.init(title: "x", entries: [],
                                nextURL: nil, searchDescriptorURL: nil)),
        ])
        let loader = FeedLoader(opds: opds, initialURL: url)
        await loader.loadFirstPage()
        await loader.refresh()
        #expect(opds.invalidatedURLs.contains(url))
    }

    @Test func networkFailurePreservesEntries() async {
        struct BoomError: Error {}
        let url = URL(string: "https://example/opds/")!
        let opds = FakeOPDSClient(responses: [
            url: .success(.init(title: "x", entries: [
                .navigation(.init(id: "a", title: "A", summary: nil,
                                  href: URL(string: "https://e/a")!))
            ], nextURL: URL(string: "https://e/?offset=60"), searchDescriptorURL: nil)),
            URL(string: "https://e/?offset=60")!: .failure(BoomError()),
        ])
        let loader = FeedLoader(opds: opds, initialURL: url)
        await loader.loadFirstPage()
        await loader.loadNextPage()
        #expect(loader.entries.count == 1) // preserved
        if case .failed = loader.phase {} else { Issue.record("expected .failed") }
    }

    @Test func refreshDuringLoadingMoreDiscardsStaleAppend() async {
        // Pull-to-refresh while infinite-scroll has a slow next-page fetch
        // in flight: the slow next-page completion must NOT append onto the
        // freshly-refreshed entries.
        let url1 = URL(string: "https://example/opds/?offset=0")!
        let url2 = URL(string: "https://example/opds/?offset=60")!
        let pub: (String) -> OPDSFeed.Entry = { id in
            .acquisition(.init(serverID: id, title: id, authors: [],
                               summary: nil, publishedAt: nil,
                               acquisitions: [.init(href: URL(string: "https://e/\(id).epub")!,
                                                    mimeType: "application/epub+zip",
                                                    format: .epub)],
                               thumbnailURL: nil, coverURL: nil))
        }
        let opds = FakeOPDSClient(responses: [
            url1: .success(.init(title: "Stale", entries: [pub("page1")],
                                 nextURL: url2, searchDescriptorURL: nil)),
            url2: .delayedSuccess(.init(title: "x", entries: [pub("stale-page2")],
                                        nextURL: nil, searchDescriptorURL: nil),
                                  delayNanoseconds: 200_000_000),
        ])
        let loader = FeedLoader(opds: opds, initialURL: url1)
        await loader.loadFirstPage()
        // Start a slow next-page fetch.
        async let inFlightNext: () = loader.loadNextPage()
        // Yield briefly so loadNextPage enters its await.
        try? await Task.sleep(nanoseconds: 30_000_000)
        // Refresh swaps url1's response. The slow next-page completion will
        // arrive AFTER refresh has reset entries; the generation guard must
        // drop its append.
        opds.responses[url1] = .success(.init(title: "Fresh",
                                              entries: [pub("fresh")],
                                              nextURL: nil, searchDescriptorURL: nil))
        await loader.refresh()
        // Let the stale next-page fetch finish (it should be discarded).
        await inFlightNext

        #expect(loader.entries.map(\.id) == ["fresh"])
        #expect(loader.title == "Fresh")
        // Phase should be the refresh's terminal state (.loaded), not whatever
        // the stale loadNextPage tried to set last.
        if case .loaded = loader.phase {} else {
            Issue.record("expected .loaded, got \(loader.phase)")
        }
    }
}

// MARK: - Fakes

@MainActor
final class FakeOPDSClient: OPDSClientProtocol {
    enum Response {
        case success(OPDSFeed)
        case failure(Error)
        case delayedSuccess(OPDSFeed, delayNanoseconds: UInt64)
    }

    var responses: [URL: Response]
    private(set) var invalidatedURLs: Set<URL> = []
    private var requestCounts: [URL: Int] = [:]

    init(responses: [URL: Response]) { self.responses = responses }

    func fetchFeed(url: URL) async throws -> OPDSFeed {
        requestCounts[url, default: 0] += 1
        switch responses[url] {
        case .success(let f): return f
        case .failure(let e): throw e
        case .delayedSuccess(let f, let ns):
            try? await Task.sleep(nanoseconds: ns)
            return f
        case .none:
            throw NSError(domain: "fake", code: 1)
        }
    }

    func fetchSearchDescriptor(at url: URL) async throws -> OpenSearchDescriptor {
        throw NSError(domain: "fake", code: 1)
    }

    func invalidate(_ url: URL) async { invalidatedURLs.insert(url) }
    func invalidateAll() async {}
    func requestCount(for url: URL) -> Int { requestCounts[url] ?? 0 }
}
