import Foundation

public enum SyncProtocol: String, Sendable, Codable {
    case kosync
    case kobo
}

/// Combined credentials for a single Calibre-Web-Automated server: the URL
/// plus HTTP Basic credentials. Same credentials cover both `/opds/` and
/// `/kosync` on CWA.
public struct ServerCredentials: Sendable, Equatable {
    public let serverURL: URL
    public let basic: BasicCredentials

    public init(serverURL: URL, basic: BasicCredentials) {
        self.serverURL = serverURL
        self.basic = basic
    }
}

/// Kobo sync credentials. `baseURL` is treated as a secret because the auth
/// token is encoded in its path (CWA's `/kobo/{TOKEN}/` scheme).
/// `imageURLTemplate` is populated after the first `/v1/initialization`
/// response and persisted so the cover-rendering pipeline survives restarts.
public struct KoboCredentials: Sendable, Equatable {
    public let baseURL: URL
    public let imageURLTemplate: String?

    public init(baseURL: URL, imageURLTemplate: String? = nil) {
        self.baseURL = baseURL
        self.imageURLTemplate = imageURLTemplate
    }
}

/// Read-only access to per-source credentials. Adopted by `AuthStore` and
/// `TransientAuthStore` (Task 13) so `BackendFactory.build` can accept either.
public protocol AuthReading: Sendable {
    func load(sourceID: UUID) throws -> ServerCredentials?
    func loadKobo(sourceID: UUID) throws -> KoboCredentials?
}

/// Persists per-source sync credentials.
/// Secrets (passwords, Kobo base URLs whose paths encode auth tokens) live in
/// `KeychainStore`; non-secret config (server URLs, usernames,
/// imageURLTemplates) lives in `UserDefaults`.
public final class AuthStore: Sendable {
    private let keychain: KeychainStore
    // UserDefaults lacks a formal Sendable conformance in Swift 6, but its
    // get/set operations are thread-safe (serialised internally by Foundation).
    // nonisolated(unsafe) opts this property out of actor-isolation checking
    // while keeping the class Sendable.
    private nonisolated(unsafe) let defaults: UserDefaults

    public init(
        keychain: KeychainStore = .init(service: "com.raphi011.kios.credentials"),
        defaults: UserDefaults = .standard
    ) {
        self.keychain = keychain
        self.defaults = defaults
    }

    // MARK: - Source-keyed API

    // UserDefaults keys
    private static func kosyncServerURLKey(for id: UUID) -> String {
        "Kios.source.\(id.uuidString).kosync.serverURL"
    }
    private static func kosyncUsernameKey(for id: UUID) -> String {
        "Kios.source.\(id.uuidString).kosync.username"
    }
    private static func koboImageURLTemplateKey(for id: UUID) -> String {
        "Kios.source.\(id.uuidString).kobo.imageURLTemplate"
    }

    // Keychain accounts
    private static func kosyncPasswordAccount(for id: UUID) -> String {
        "source.\(id.uuidString).kosync.password"
    }
    private static func koboBaseURLAccount(for id: UUID) -> String {
        "source.\(id.uuidString).kobo.baseURL"
    }

    /// Saves kosync credentials for `sourceID`. Replaces any existing entry.
    public func save(sourceID: UUID, credentials: ServerCredentials) throws {
        defaults.set(credentials.serverURL.absoluteString, forKey: Self.kosyncServerURLKey(for: sourceID))
        defaults.set(credentials.basic.username, forKey: Self.kosyncUsernameKey(for: sourceID))
        try keychain.set(credentials.basic.password, account: Self.kosyncPasswordAccount(for: sourceID))
    }

    /// Returns kosync credentials for `sourceID`, or nil if any part is missing.
    public func load(sourceID: UUID) throws -> ServerCredentials? {
        guard
            let urlString = defaults.string(forKey: Self.kosyncServerURLKey(for: sourceID)),
            let url = URL(string: urlString),
            let username = defaults.string(forKey: Self.kosyncUsernameKey(for: sourceID)),
            let password = try keychain.get(account: Self.kosyncPasswordAccount(for: sourceID))
        else { return nil }
        return ServerCredentials(serverURL: url, basic: .init(username: username, password: password))
    }

    /// Saves Kobo credentials for `sourceID`. `baseURL` goes to Keychain;
    /// `imageURLTemplate` goes to UserDefaults.
    public func save(sourceID: UUID, kobo: KoboCredentials) throws {
        try keychain.set(kobo.baseURL.absoluteString, account: Self.koboBaseURLAccount(for: sourceID))
        if let tmpl = kobo.imageURLTemplate {
            defaults.set(tmpl, forKey: Self.koboImageURLTemplateKey(for: sourceID))
        } else {
            defaults.removeObject(forKey: Self.koboImageURLTemplateKey(for: sourceID))
        }
    }

    /// Returns Kobo credentials for `sourceID`, or nil if baseURL is missing.
    public func loadKobo(sourceID: UUID) throws -> KoboCredentials? {
        guard let urlString = try keychain.get(account: Self.koboBaseURLAccount(for: sourceID)),
              let url = URL(string: urlString) else { return nil }
        let tmpl = defaults.string(forKey: Self.koboImageURLTemplateKey(for: sourceID))
        return KoboCredentials(baseURL: url, imageURLTemplate: tmpl)
    }

    /// Deletes all stored data (kosync + kobo) for `sourceID`. Idempotent.
    public func purge(sourceID: UUID) throws {
        defaults.removeObject(forKey: Self.kosyncServerURLKey(for: sourceID))
        defaults.removeObject(forKey: Self.kosyncUsernameKey(for: sourceID))
        defaults.removeObject(forKey: Self.koboImageURLTemplateKey(for: sourceID))
        try keychain.delete(account: Self.kosyncPasswordAccount(for: sourceID))
        try keychain.delete(account: Self.koboBaseURLAccount(for: sourceID))
    }
}

extension AuthStore: AuthReading {}
