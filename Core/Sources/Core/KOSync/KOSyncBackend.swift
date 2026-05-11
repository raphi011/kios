import Foundation

/// Adapts `KOSyncClient` to the backend-agnostic `SyncBackend` protocol.
///
/// The kosync wire format embeds chapter index + intra-chapter progression as a
/// `"<chapter>:<intra>"` string. We piggy-back on `CanonicalProgress.locatorJSON`
/// to carry that pre-formatted string through the sync pipeline; when missing
/// (e.g. a fresh progress not built from a kosync-aware locator) we fall back
/// to `"0:0.0000"`. The full Readium ↔ kosync translation lives in
/// `KOSyncProgressMapper` and is invoked at a higher layer.
public struct KOSyncBackend: SyncBackend {
    public let client: KOSyncClient
    public let deviceID: String
    public let deviceName: String

    public init(client: KOSyncClient, deviceID: String, deviceName: String) {
        self.client = client
        self.deviceID = deviceID
        self.deviceName = deviceName
    }

    public func authenticate() async throws {
        _ = try await client.authenticate()
    }

    public func fetchProgress(for id: BookIdentity) async throws -> CanonicalProgress? {
        guard let hash = id.partialMD5 else {
            throw BackendError.identityMissing(field: "partialMD5")
        }
        guard let server = try await client.getProgress(documentHash: hash) else {
            return nil
        }
        return CanonicalProgress(
            percentage: server.percentage,
            locatorJSON: nil,
            timestamp: server.timestamp.map { Date(timeIntervalSince1970: $0) } ?? Date(),
            deviceID: server.deviceID,
            deviceName: server.device
        )
    }

    public func pushProgress(_ p: CanonicalProgress, for id: BookIdentity) async throws {
        guard let hash = id.partialMD5 else {
            throw BackendError.identityMissing(field: "partialMD5")
        }
        let progressString = p.locatorJSON ?? "0:0.0000"
        try await client.putProgress(.init(
            document: hash,
            progress: progressString,
            percentage: p.percentage,
            device: deviceName,
            deviceID: deviceID
        ))
    }
}
