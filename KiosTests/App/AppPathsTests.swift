import Testing
import Foundation
@testable import Kios

@Suite("AppPaths")
struct AppPathsTests {
    @Test func coverFilenameFormat() {
        let id = UUID()
        let name = AppPaths.coverFilename(for: id)
        #expect(name == "\(id.uuidString).cover.jpg")
    }
}
