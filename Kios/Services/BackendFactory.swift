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
        let proto = auth.loadActiveProtocol()
        switch proto {
        case .kosync:
            guard let creds = try auth.load() else {
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
            guard let creds = try auth.loadKobo() else {
                throw BackendFactoryError.missingCredentials(.kobo)
            }
            let backend = makeKoboBackend(
                creds: creds, deviceID: deviceID, deviceName: deviceName
            )
            // Same actor instance fills both slots — `KoboBackend` conforms
            // to `SyncBackend` and `CatalogBackend` and shares cached state
            // (e.g. `imageURLTemplate`) between the two roles.
            return (backend, backend)
        }
    }

    /// Build a `SyncBackend` for an explicit protocol, regardless of the
    /// active selection. Used by `SyncService` to honor `pendingProtocol`
    /// at flush time so a buffered write under one protocol still flushes
    /// via that protocol's backend even after the user switches.
    static func buildSync(
        auth: AuthStore,
        protocol proto: SyncProtocol,
        deviceID: String,
        deviceName: String
    ) throws -> any SyncBackend {
        switch proto {
        case .kosync:
            guard let creds = try auth.load() else {
                throw BackendFactoryError.missingCredentials(.kosync)
            }
            let http = HTTPClient(credentials: creds.basic)
            return makeKOSyncBackend(
                creds: creds, http: http,
                deviceID: deviceID, deviceName: deviceName
            )

        case .kobo:
            guard let creds = try auth.loadKobo() else {
                throw BackendFactoryError.missingCredentials(.kobo)
            }
            return makeKoboBackend(
                creds: creds, deviceID: deviceID, deviceName: deviceName
            )
        }
    }

    // MARK: - private

    private static func makeKOSyncBackend(
        creds: ServerCredentials,
        http: HTTPClient,
        deviceID: String,
        deviceName: String
    ) -> KOSyncBackend {
        let kosyncClient = KOSyncClient(
            baseURL: creds.serverURL.appendingPathComponent("kosync"),
            http: http
        )
        return KOSyncBackend(
            client: kosyncClient,
            deviceID: deviceID,
            deviceName: deviceName
        )
    }

    private static func makeKoboBackend(
        creds: KoboCredentials,
        deviceID: String,
        deviceName: String
    ) -> KoboBackend {
        // Kobo auth is encoded in the URL path (`/kobo/{TOKEN}/`), not
        // in an Authorization header — so no BasicCredentials here.
        let http = HTTPClient()
        let koboClient = KoboClient(baseURL: creds.baseURL, http: http, deviceID: deviceID)
        return KoboBackend(
            client: koboClient,
            deviceID: deviceID,
            deviceName: deviceName,
            imageURLTemplate: creds.imageURLTemplate
        )
    }
}

enum BackendFactoryError: Error, Equatable {
    case missingCredentials(SyncProtocol)
}
