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
        phase = .loading
        do {
            let feed = try await opds.fetchFeed(url: initialURL)
            title = feed.title
            entries = feed.entries
            nextURL = feed.nextURL
            searchDescriptorURL = feed.searchDescriptorURL
            phase = .loaded
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Appends the next page. No-op if there is none or a load is already in flight.
    func loadNextPage() async {
        guard let url = nextURL, phase != .loadingMore else { return }
        phase = .loadingMore
        do {
            let feed = try await opds.fetchFeed(url: url)
            entries.append(contentsOf: feed.entries)
            nextURL = feed.nextURL
            phase = .loaded
        } catch {
            phase = .failed(error.localizedDescription)
            // entries deliberately preserved — don't blank the UI on transient errors
        }
    }

    /// Pull-to-refresh. Drops the cache entry for `initialURL` so the next fetch
    /// goes to the network, then resets pagination state.
    func refresh() async {
        await opds.invalidate(initialURL)
        entries = []
        nextURL = nil
        searchDescriptorURL = nil
        await loadFirstPage()
    }
}
