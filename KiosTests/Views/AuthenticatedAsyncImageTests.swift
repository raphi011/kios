import Testing
import Foundation
import UIKit
@testable import Kios

@Suite("ImageMemoryCache")
struct ImageMemoryCacheTests {
    @Test func storesAndRetrievesByURL() {
        let cache = ImageMemoryCache()
        let url = URL(string: "https://example/cover.jpg")!
        let img = UIImage(systemName: "book")!
        cache.store(img, for: url)
        #expect(cache.image(for: url) === img)
    }

    @Test func returnsNilForUnseenURL() {
        let cache = ImageMemoryCache()
        #expect(cache.image(for: URL(string: "https://nope")!) == nil)
    }

    @Test func removeAllEmptiesCache() {
        let cache = ImageMemoryCache()
        let url = URL(string: "https://example/cover.jpg")!
        cache.store(UIImage(systemName: "book")!, for: url)
        cache.removeAll()
        #expect(cache.image(for: url) == nil)
    }
}
