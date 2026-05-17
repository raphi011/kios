import Foundation
import SwiftData
import Core

@Model
final class ReadingProgress {
    @Attribute(.unique) var bookID: UUID
    var locatorJSON: String
    /// kosync-format "chapter|intra" string. Nil for Kobo books, which carry
    /// their location in `koboLocationSource` + `koboLocationValue` instead.
    var koSyncProgressString: String?
    var koboLocationSource: String?
    var koboLocationValue: String?
    var percentage: Double          // 0.0 ... 1.0
    var updatedAt: Date
    var deviceID: String
    var pendingUpload: Bool

    init(
        bookID: UUID,
        locatorJSON: String,
        koSyncProgressString: String?,
        koboLocationSource: String?,
        koboLocationValue: String?,
        percentage: Double,
        updatedAt: Date,
        deviceID: String,
        pendingUpload: Bool
    ) {
        self.bookID = bookID
        self.locatorJSON = locatorJSON
        self.koSyncProgressString = koSyncProgressString
        self.koboLocationSource = koboLocationSource
        self.koboLocationValue = koboLocationValue
        self.percentage = percentage
        self.updatedAt = updatedAt
        self.deviceID = deviceID
        self.pendingUpload = pendingUpload
    }

    var canonical: CanonicalProgress {
        CanonicalProgress(
            percentage: percentage,
            locatorJSON: locatorJSON,
            timestamp: updatedAt,
            deviceID: deviceID,
            deviceName: ""   // SyncService fills this in
        )
    }
}
