import Foundation
import Core

enum BackendFactory {
    /// Returns the (sync, catalog) pair for the given source. `sync` is `nil`
    /// when the source kind has no sync protocol (`.local`, `.opdsReadOnly`).
    /// Throws when a server kind has no credentials in `auth`.
    /// `auth` is a protocol so `AppEnvironment.addSource` can probe with a
    /// `TransientAuthStore` before the source is persisted to SwiftData.
    static func build(
        source: Source,
        auth: any AuthReading,
        deviceID: String,
        deviceName: String
    ) throws -> (sync: (any SyncBackend)?, catalog: any CatalogBackend) {
        switch source.kind {
        case .local:
            return (nil, LocalImportCatalog())

        case .opdsReadOnly:
            guard let serverURL = source.serverURL else {
                throw BackendFactoryError.missingServerURL
            }
            let http = HTTPClient()
            let opdsClient = OPDSClient(http: http)
            let catalog = OPDSCatalogAdapter(
                client: opdsClient,
                rootURL: serverURL
            )
            return (nil, catalog)

        case .kosync:
            guard let creds = try auth.load(sourceID: source.id) else {
                throw BackendFactoryError.missingCredentials(.kosync)
            }
            let http = HTTPClient(credentials: creds.basic)
            let sync = makeKOSyncBackend(
                creds: creds, http: http,
                deviceID: deviceID, deviceName: deviceName
            )
            let opdsClient = OPDSClient(http: http)
            let catalog = OPDSCatalogAdapter(
                client: opdsClient,
                rootURL: creds.serverURL.appendingPathComponent("opds/")
            )
            return (sync, catalog)

        case .kobo:
            guard let creds = try auth.loadKobo(sourceID: source.id) else {
                throw BackendFactoryError.missingCredentials(.kobo)
            }
            let backend = makeKoboBackend(
                creds: creds, deviceID: deviceID, deviceName: deviceName
            )
            // KoboBackend conforms to both SyncBackend and CatalogBackend
            // and caches imageURLTemplate across the two roles.
            return (backend, backend)
        }
    }

    private static func makeKOSyncBackend(
        creds: ServerCredentials,
        http: HTTPClient,
        deviceID: String,
        deviceName: String
    ) -> KOSyncBackend {
        let client = KOSyncClient(
            baseURL: creds.serverURL.appendingPathComponent("kosync"),
            http: http
        )
        return KOSyncBackend(
            client: client, deviceID: deviceID, deviceName: deviceName
        )
    }

    private static func makeKoboBackend(
        creds: KoboCredentials,
        deviceID: String,
        deviceName: String
    ) -> KoboBackend {
        // Kobo auth lives in the URL path (`/kobo/{TOKEN}/`), not in an
        // Authorization header — so no BasicCredentials here.
        let http = HTTPClient()
        let client = KoboClient(
            baseURL: creds.baseURL, http: http, deviceID: deviceID
        )
        return KoboBackend(
            client: client,
            deviceID: deviceID,
            deviceName: deviceName,
            imageURLTemplate: creds.imageURLTemplate
        )
    }
}

enum BackendFactoryError: Error, Equatable {
    case missingCredentials(SyncProtocol)
    case missingServerURL
}
