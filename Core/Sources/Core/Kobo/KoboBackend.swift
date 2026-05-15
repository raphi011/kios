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
///
/// Implemented as an `actor` (rather than a `class` + `@unchecked Sendable`)
/// because `listLibrary`/`authenticate` mutate cached state across suspension
/// points. The type system enforces serial access; callers can pass instances
/// freely across task boundaries.
public actor KoboBackend: SyncBackend, CatalogBackend {
    public nonisolated let client: KoboClient
    public nonisolated let deviceID: String
    public nonisolated let deviceName: String

    private var imageURLTemplate: String?

    /// `imageURLTemplate` primes the cover-rendering cache from a previously-
    /// persisted `/v1/initialization` response so `listLibrary` doesn't need to
    /// re-authenticate when the template is already known. Pass `nil` to force
    /// `listLibrary` to call `authenticate()` on the first invocation.
    public init(client: KoboClient, deviceID: String, deviceName: String, imageURLTemplate: String?) {
        self.client = client
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.imageURLTemplate = imageURLTemplate
    }

    public func authenticate() async throws {
        let res = try await client.initialization()
        self.imageURLTemplate = res.imageURLTemplate
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
        // Echo the bookmark's `DeviceId` when the (patched) CWA returns it;
        // stock CWA omits the field and every peer write looks anonymous.
        return CanonicalProgress(
            percentage: percentage,
            locatorJSON: locatorJSON,
            timestamp: timestamp,
            deviceID: bookmark.deviceId ?? "kobo-peer",
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

    // MARK: - CatalogBackend

    public func listLibrary() async throws -> [CatalogEntry] {
        if imageURLTemplate == nil {
            try await authenticate()
        }
        // v1: full-sync each call. Incremental sync (passing the previous
        // nextSyncToken back) lands when persistence of the token across app
        // launches is wired up; storing it only in memory would mean a
        // restart silently degrades a "should-be-incremental" sync into a
        // full one with no diagnostic.
        let result = try await client.librarySync(syncToken: nil)

        var entries: [CatalogEntry] = []
        for entry in result.entries {
            switch entry {
            case .newEntitlement(let e), .changedEntitlement(let e):
                guard let mapped = mapEntitlement(e) else { continue }
                entries.append(mapped)
            default:
                break
            }
        }
        return entries
    }

    public func resolveDownload(for entry: CatalogEntry) async throws -> URL {
        // CWA's download URLs are direct GETs; nothing to resolve.
        entry.downloadURL
    }

    private func mapEntitlement(_ e: KoboEntitlement) -> CatalogEntry? {
        let bm = e.bookMetadata
        let kepub = bm.downloadUrls.first { $0.format == "KEPUB" }
        let chosen = kepub ?? bm.downloadUrls.first { $0.format == "EPUB" || $0.format == "EPUB3" || $0.format == "EPUB3FL" }
        guard let download = chosen else { return nil }

        let thumb: URL? = {
            guard let template = imageURLTemplate, let coverId = bm.coverImageId else { return nil }
            return URL(string: template
                .replacingOccurrences(of: "{ImageId}", with: coverId)
                .replacingOccurrences(of: "{width}", with: "1200")
                .replacingOccurrences(of: "{height}", with: "1600"))
        }()

        return CatalogEntry(
            serverID: bm.entitlementId,
            title: bm.title,
            authors: bm.contributors,
            identity: BookIdentity(partialMD5: nil, koboBookUUID: bm.entitlementId),
            downloadURL: download.url,
            format: .epub,
            thumbnailURL: thumb
        )
    }
}

/// CWA's Kobo blueprint timestamps come from various sources; some include
/// fractional seconds, some don't. Try the strict variant first then fall
/// back to plain ISO8601.
private func isoDate(_ s: String) -> Date? {
    let withFractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    let withoutFractional = Date.ISO8601FormatStyle()
    return (try? withFractional.parse(s)) ?? (try? withoutFractional.parse(s))
}
