import SwiftUI
import Core
import os

private extension Logger {
    static let thumbnail = Logger(subsystem: "com.raphi011.kios", category: "thumbnail")
}

/// SwiftUI image view backed by `ImageMemoryCache` for instant render
/// on cache hits — every thumbnail across the library funnels through
/// here so navigating filters / tabs doesn't reflash placeholders.
///
/// Loader dispatch:
/// - `file://` → `Data(contentsOf:)` off-main (URLCache doesn't cover
///   file URLs; the memory cache is what kills the flash).
/// - `http(s)://` with `http` set → `Core.HTTPClient` (kosync Basic auth;
///   stock `AsyncImage` can't carry an Authorization header).
/// - `http(s)://` otherwise → `URLSession.shared` (URLCache.shared keeps
///   the encoded bytes warm on disk).
///
/// `init` seeds `@State image` from `ImageMemoryCache.shared` so a hit
/// paints on the first frame. Fresh fetches decode then store the
/// `UIImage` back into the cache on success.
struct CachedAsyncImage<Placeholder: View>: View {
    let url: URL?
    let http: Core.HTTPClient?
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: UIImage?

    init(
        url: URL?,
        http: Core.HTTPClient? = nil,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.url = url
        self.http = http
        self.placeholder = placeholder
        let cached = url.flatMap { ImageMemoryCache.shared.image(for: $0) }
        self._image = State(initialValue: cached)
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable()
            } else {
                placeholder()
            }
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        guard let url else {
            image = nil
            return
        }
        if let cached = ImageMemoryCache.shared.image(for: url) {
            if image !== cached { image = cached }
            return
        }
        image = nil   // entering load path — clear stale image while we wait
        do {
            let data = try await fetch(url)
            guard let decoded = UIImage(data: data) else { return }
            ImageMemoryCache.shared.store(decoded, for: url)
            image = decoded
        } catch {
            // Thumbnails fail silently in the UI (placeholder remains visible);
            // log so a developer attached to the session can diagnose 401s,
            // network drops, decode failures, or missing on-disk covers.
            Logger.thumbnail.debug("CachedAsyncImage fetch failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func fetch(_ url: URL) async throws -> Data {
        if url.isFileURL {
            // Hop off the main actor for the disk read — `Data(contentsOf:)`
            // is blocking and `.task` inherits the View's main-actor isolation.
            return try await Task.detached(priority: .userInitiated) {
                try Data(contentsOf: url)
            }.value
        }
        if let http {
            let (data, _) = try await http.data(for: URLRequest(url: url))
            return data
        }
        let (data, _) = try await URLSession.shared.data(for: URLRequest(url: url))
        return data
    }
}
