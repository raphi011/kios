import Foundation
import SwiftData

@Model
final class ReadingProgress {
    @Attribute(.unique) var bookID: UUID
    var locatorJSON: String
    var percentage: Double          // 0.0 ... 1.0
    var updatedAt: Date
    var deviceID: String
    var pendingUpload: Bool

    init(
        bookID: UUID,
        locatorJSON: String,
        percentage: Double,
        updatedAt: Date,
        deviceID: String,
        pendingUpload: Bool = false
    ) {
        self.bookID = bookID
        self.locatorJSON = locatorJSON
        self.percentage = percentage
        self.updatedAt = updatedAt
        self.deviceID = deviceID
        self.pendingUpload = pendingUpload
    }
}
