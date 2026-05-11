import Foundation

/// View-model driving a `FeedView`. Owns the per-feed paginated state and
/// surfaces `phase` for spinners + error banners. Lives in @State on the view
/// it backs; never shared between views.
@Observable
@MainActor
final class FeedLoader {
    let opds: OPDSClientProtocol
    let initialURL: URL

    private(set) var title: String = ""
    private(set) var entries: [OPDSFeed.Entry] = []
    private(set) var nextURL: URL?
    private(set) var searchDescriptorURL: URL?
    private(set) var phase: Phase = .idle

    /// Monotonic generation tag. Bumped by `refresh()` so any in-flight
    /// load that completes after a refresh sees `myGen != loadGeneration`
    /// and discards its result instead of appending stale entries onto
    /// the freshly-loaded list.
    private var loadGeneration: UInt = 0

    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case loadingMore
        case failed(String)
    }

    init(opds: OPDSClientProtocol, initialURL: URL) {
        self.opds = opds
        self.initialURL = initialURL
    }

    /// Fetches the first page. Replaces existing entries.
    func loadFirstPage() async {
        guard phase != .loading else { return }
        let myGen = loadGeneration
        phase = .loading
        do {
            let feed = try await opds.fetchFeed(url: initialURL)
            guard myGen == loadGeneration else { return }
            title = feed.title
            entries = feed.entries
            nextURL = feed.nextURL
            searchDescriptorURL = feed.searchDescriptorURL
            phase = .loaded
        } catch {
            guard myGen == loadGeneration else { return }
            phase = .failed(error.localizedDescription)
        }
    }

    /// Appends the next page. No-op if there is none or a load is already in flight.
    func loadNextPage() async {
        guard let url = nextURL, phase != .loadingMore else { return }
        let myGen = loadGeneration
        phase = .loadingMore
        do {
            let feed = try await opds.fetchFeed(url: url)
            guard myGen == loadGeneration else { return }
            entries.append(contentsOf: feed.entries)
            nextURL = feed.nextURL
            phase = .loaded
        } catch {
            guard myGen == loadGeneration else { return }
            phase = .failed(error.localizedDescription)
            // entries deliberately preserved — don't blank the UI on transient errors
        }
    }

    /// Pull-to-refresh. Bumps the load generation so any in-flight page
    /// fetch is discarded on completion, drops the cache entry for
    /// `initialURL`, resets pagination state, then re-loads.
    func refresh() async {
        loadGeneration += 1
        await opds.invalidate(initialURL)
        entries = []
        nextURL = nil
        searchDescriptorURL = nil
        await loadFirstPage()
    }
}
