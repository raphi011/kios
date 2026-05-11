import Foundation
import Core

/// Builds the `SyncBackend` + `CatalogBackend` pair appropriate for the
/// user's currently-selected sync protocol. Existentials are returned so
/// `SyncService` and `LibraryService` can compose without knowing which
/// protocol is active.
enum BackendFactory {
    /// `auth` must already have all required state for the requested
    /// protocol persisted (server creds for kosync, kobo creds for kobo).
    /// Throws `BackendFactoryError.missingCredentials` if any of the
    /// required state is absent.
    static func build(
        auth: AuthStore,
        deviceID: String,
        deviceName: String
    ) throws -> (sync: any SyncBackend, catalog: any CatalogBackend) {
        switch auth.loadActiveProtocol() {
        case .kosync:
            guard let creds = try auth.load() else {
                throw BackendFactoryError.missingCredentials(.kosync)
            }
            let http = HTTPClient(credentials: creds.basic)
            let kosyncClient = KOSyncClient(
                baseURL: creds.serverURL.appendingPathComponent("kosync"),
                http: http
            )
            let sync = KOSyncBackend(
                client: kosyncClient,
                deviceID: deviceID,
                deviceName: deviceName
            )
            let opdsClient = OPDSClient(http: http)
            let catalog = OPDSCatalogAdapter(
                client: opdsClient,
                rootURL: creds.serverURL.appendingPathComponent("opds/")
            )
            return (sync, catalog)

        case .kobo:
            guard let creds = try auth.loadKobo() else {
                throw BackendFactoryError.missingCredentials(.kobo)
            }
            // Kobo auth is encoded in the URL path (`/kobo/{TOKEN}/`), not
            // in an Authorization header — so no BasicCredentials here.
            let http = HTTPClient()
            let koboClient = KoboClient(baseURL: creds.baseURL, http: http)
            let backend = KoboBackend(
                client: koboClient,
                deviceID: deviceID,
                deviceName: deviceName,
                imageURLTemplate: creds.imageURLTemplate
            )
            // Same actor instance fills both slots — `KoboBackend` conforms
            // to `SyncBackend` and `CatalogBackend` and shares cached state
            // (e.g. `imageURLTemplate`) between the two roles.
            return (backend, backend)
        }
    }
}

enum BackendFactoryError: Error, Equatable {
    case missingCredentials(SyncProtocol)
}
