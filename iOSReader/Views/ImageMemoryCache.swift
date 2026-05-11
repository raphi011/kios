import UIKit

/// In-memory thumbnail cache, keyed by URL. NSCache evicts under memory pressure.
/// Single shared instance used by every AuthenticatedAsyncImage instance.
final class ImageMemoryCache {
    static let shared = ImageMemoryCache()

    private let cache = NSCache<NSURL, UIImage>()

    init(costLimitBytes: Int = 50 * 1024 * 1024) {
        cache.totalCostLimit = costLimitBytes
    }

    func image(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    func store(_ image: UIImage, for url: URL) {
        // Cost ≈ pixels × 4 bytes (RGBA). Safe overapproximation.
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        cache.setObject(image, forKey: url as NSURL, cost: cost)
    }

    func removeAll() {
        cache.removeAllObjects()
    }
}
