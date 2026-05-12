import Foundation

/// Adapts `KOSyncClient` to the backend-agnostic `SyncBackend` protocol.
///
/// The kosync wire format embeds chapter index + intra-chapter
/// progression as a `"<chapter>:<intra>"` string. We extract the
/// intra-chapter progression from the Readium locator JSON's
/// `locations.progression` field and hardcode chapter=0 — Readium
/// locators don't carry a usable chapter index, and the global
/// `percentage` field handles cross-device sync regardless. Peer
/// readers (KOReader, etc.) that read our `progress` will see a
/// chapter-0 anchor but a correct global percentage.
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
            // `.distantPast` (not `Date()`) when server omits the timestamp:
            // LWW reconciliation must treat "age unknown" as "oldest possible"
            // so it never beats a real local write.
            timestamp: server.timestamp.map { Date(timeIntervalSince1970: $0) } ?? .distantPast,
            deviceID: server.deviceID,
            deviceName: server.device
        )
    }

    public func pushProgress(_ p: CanonicalProgress, for id: BookIdentity) async throws {
        guard let hash = id.partialMD5 else {
            throw BackendError.identityMissing(field: "partialMD5")
        }
        let intra = Self.extractIntraProgression(fromLocatorJSON: p.locatorJSON)
        // Chapter index is intentionally 0 — Readium locators don't carry an
        // explicit chapter index, and reconstructing one from `href` requires
        // the publication's reading order. KOReader peers fall back to the
        // global `percentage` for position recovery, which is correct.
        let progressString = KOSyncProgressMapper.encodeProgress(
            chapter: 0,
            intraProgression: intra
        )
        try await client.putProgress(.init(
            document: hash,
            progress: progressString,
            percentage: p.percentage,
            device: deviceName,
            deviceID: deviceID
        ))
    }

    /// Parses a Readium locator JSON string and returns
    /// `locations.progression`, or 0.0 if the field is absent or the JSON
    /// can't be parsed (e.g. nil, malformed, or non-JSON content). Defaults
    /// to 0 — meaning "start of this chapter" — which is the safest position
    /// for a peer reader to seek to if our intra-progression is unknown.
    static func extractIntraProgression(fromLocatorJSON json: String?) -> Double {
        guard let json,
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let locations = obj["locations"] as? [String: Any],
              let progression = locations["progression"] as? Double else {
            return 0
        }
        return min(max(progression, 0), 1)
    }
}
