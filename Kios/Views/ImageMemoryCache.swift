import UIKit

/// In-memory thumbnail cache, keyed by URL. NSCache evicts under memory pressure.
/// Single shared instance used by every AuthenticatedAsyncImage instance.
///
/// NSCache is documented thread-safe, so the only mutable state here lives
/// behind that — hence `@unchecked Sendable` is correct.
final class ImageMemoryCache: @unchecked Sendable {
    static let shared = ImageMemoryCache()

    private let cache = NSCache<NSURL, UIImage>()
    private let colorCache = NSCache<NSURL, UIColor>()

    init(costLimitBytes: Int = 50 * 1024 * 1024) {
        cache.totalCostLimit = costLimitBytes
        // Colors are ~16 bytes each; 4096 entries is well under 100KB.
        colorCache.countLimit = 4096
    }

    func image(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    func store(_ image: UIImage, for url: URL) {
        // UIImage.size is in points; total pixels = (size × scale)². ×4 for RGBA.
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        cache.setObject(image, forKey: url as NSURL, cost: cost)
    }

    func color(for url: URL) -> UIColor? {
        colorCache.object(forKey: url as NSURL)
    }

    func storeColor(_ color: UIColor, for url: URL) {
        colorCache.setObject(color, forKey: url as NSURL)
    }

    func removeAll() {
        cache.removeAllObjects()
        colorCache.removeAllObjects()
    }
}
