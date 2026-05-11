import SwiftUI
import Core
import os

private extension Logger {
    static let thumbnail = Logger(subsystem: "me.iosreader.iOSReader", category: "thumbnail")
}

/// SwiftUI image view that fetches with HTTP Basic auth via `HTTPClient`.
/// `AsyncImage` is unusable for this — it uses `URLSession.shared` and has no hook
/// for an Authorization header, so authenticated thumbnails would silently 401.
///
/// Init seeds `@State image` from `ImageMemoryCache.shared` so a cache hit renders
/// the image on the first frame — no placeholder flash when scrolling back over
/// rows you've already loaded. On miss, fetches via `http` and stores the decoded
/// `UIImage` in the cache. `URLCache.shared` (configured at app boot) handles
/// encoded-byte caching on disk.
struct AuthenticatedAsyncImage<Placeholder: View>: View {
    let url: URL?
    let http: Core.HTTPClient
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: UIImage?

    init(url: URL?, http: Core.HTTPClient,
         @ViewBuilder placeholder: @escaping () -> Placeholder) {
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
        image = nil   // entering network path — clear stale image while we wait
        do {
            let (data, _) = try await http.data(for: URLRequest(url: url))
            guard let decoded = UIImage(data: data) else { return }
            ImageMemoryCache.shared.store(decoded, for: url)
            image = decoded
        } catch {
            // Thumbnails fail silently in the UI (placeholder remains visible);
            // log so a developer attached to the session can diagnose 401s,
            // network drops, or decode failures.
            Logger.thumbnail.debug("AuthenticatedAsyncImage fetch failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
