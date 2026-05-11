import SwiftUI
import Core

/// SwiftUI image view that fetches with HTTP Basic auth via `HTTPClient`.
/// `AsyncImage` is unusable for this — it uses `URLSession.shared` and has no hook
/// for an Authorization header, so authenticated thumbnails would silently 401.
///
/// First read consults `ImageMemoryCache.shared`. On miss, fetches via `http` and
/// stores the decoded `UIImage` in the cache. `URLCache.shared` (configured at app
/// boot) handles encoded-byte caching on disk.
struct AuthenticatedAsyncImage<Placeholder: View>: View {
    let url: URL?
    let http: Core.HTTPClient
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: UIImage?

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
        image = nil
        guard let url else { return }
        if let cached = ImageMemoryCache.shared.image(for: url) {
            image = cached
            return
        }
        guard let (data, _) = try? await http.data(for: URLRequest(url: url)),
              let decoded = UIImage(data: data) else { return }
        ImageMemoryCache.shared.store(decoded, for: url)
        image = decoded
    }
}
