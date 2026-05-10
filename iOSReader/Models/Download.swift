import Foundation
import SwiftData

@Model
final class Download {
    @Attribute(.unique) var bookID: UUID
    var state: DownloadState
    var bytesReceived: Int64
    var totalBytes: Int64
    var error: String?

    init(
        bookID: UUID,
        state: DownloadState = .idle,
        bytesReceived: Int64 = 0,
        totalBytes: Int64 = 0,
        error: String? = nil
    ) {
        self.bookID = bookID
        self.state = state
        self.bytesReceived = bytesReceived
        self.totalBytes = totalBytes
        self.error = error
    }
}
