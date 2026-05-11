import Foundation

/// Adapts `KoboClient` to the backend-agnostic `SyncBackend` protocol.
///
/// CWA's Kobo blueprint speaks in terms of book UUIDs (entitlement IDs), so
/// every operation requires `BookIdentity.koboBookUUID`. `fetchProgress`
/// translates a `KoboCurrentBookmark` into a Readium-style locator JSON via
/// `KoboProgressMapper.toLocator`, using `ContentSourceProgressPercent`
/// (whole-book progress) as the canonical percentage.
///
/// We don't know which peer device last touched the state — the Kobo
/// blueprint doesn't tell us — so we tag fetched progress with a sentinel
/// `deviceID = "kobo-peer"`. LWW reconciliation only cares that this is
/// *not* our own deviceID; the human-facing label stays generic ("Kobo").
public struct KoboBackend: SyncBackend {
    public let client: KoboClient
    public let deviceID: String
    public let deviceName: String

    public init(client: KoboClient, deviceID: String, deviceName: String) {
        self.client = client
        self.deviceID = deviceID
        self.deviceName = deviceName
    }

    public func authenticate() async throws {
        _ = try await client.initialization()
    }

    public func fetchProgress(for id: BookIdentity) async throws -> CanonicalProgress? {
        guard let uuid = id.koboBookUUID else {
            throw BackendError.identityMissing(field: "koboBookUUID")
        }
        guard let state = try await client.fetchState(bookUUID: uuid),
              let bookmark = state.currentBookmark else { return nil }
        let percentage = (bookmark.contentSourceProgressPercent ?? 0) / 100.0
        let locatorJSON: String? = bookmark.location.map { loc in
            KoboProgressMapper.toLocator(
                source: loc.source,
                type: loc.type,
                value: loc.value,
                progressPercent: bookmark.progressPercent ?? 0,
                totalPercent: bookmark.contentSourceProgressPercent ?? 0
            )
        }
        // `.distantPast` (not `Date()`) when the server's timestamp doesn't
        // parse: LWW reconciliation must treat "age unknown" as "oldest
        // possible" so it never beats a real local write.
        let timestamp = isoDate(state.lastModified) ?? .distantPast
        return CanonicalProgress(
            percentage: percentage,
            locatorJSON: locatorJSON,
            timestamp: timestamp,
            deviceID: "kobo-peer",
            deviceName: "Kobo"
        )
    }

    public func pushProgress(_ p: CanonicalProgress, for id: BookIdentity) async throws {
        guard let uuid = id.koboBookUUID else {
            throw BackendError.identityMissing(field: "koboBookUUID")
        }
        let bookmark = buildBookmark(from: p)
        // v1 status threshold: >=99% maps to Finished, else Reading. The
        // canonical progress doesn't carry a separate completion flag, so
        // tail-end ProgressPercent is the only signal we have.
        let update = KoboStateUpdate(readingStates: [
            .init(
                currentBookmark: bookmark,
                statusInfo: .init(status: p.percentage >= 0.99 ? .finished : .reading),
                statistics: nil
            )
        ])
        try await client.pushState(bookUUID: uuid, update: update)
    }

    /// Decodes the canonical Readium-style locator JSON back into a Kobo
    /// bookmark. Falls back to percentage-only when the locator is missing
    /// or malformed: a percentage-only update is still useful for cross-
    /// device progress, while preserving the cssSelector requires a well-
    /// formed locator we can trust.
    private func buildBookmark(from p: CanonicalProgress) -> KoboStateUpdate.State.Bookmark {
        let totalProgression = p.percentage
        guard let json = p.locatorJSON,
              let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data),
              let dict = parsed as? [String: Any] else {
            return .init(
                progressPercent: totalProgression * 100,
                contentSourceProgressPercent: totalProgression * 100,
                location: nil
            )
        }
        let href = dict["href"] as? String ?? ""
        let locations = dict["locations"] as? [String: Any] ?? [:]
        let progression = locations["progression"] as? Double ?? totalProgression
        let cssSelector = locations["cssSelector"] as? String
        // Strip the leading `#` (CSS id selector) then reverse the
        // KoboProgressMapper.escapeCSS escape so the koboSpan id round-trips.
        let koboSpan: String? = {
            guard let sel = cssSelector, sel.hasPrefix("#") else { return nil }
            return KoboProgressMapper.unescapeCSS(String(sel.dropFirst()))
        }()
        return KoboProgressMapper.toKoboBookmark(
            href: href,
            koboSpanId: koboSpan,
            progression: progression,
            totalProgression: totalProgression
        )
    }
}

/// CWA's Kobo blueprint timestamps come from various sources; some include
/// fractional seconds, some don't. Try the strict variant first then fall
/// back to plain ISO8601.
private func isoDate(_ s: String) -> Date? {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
}
