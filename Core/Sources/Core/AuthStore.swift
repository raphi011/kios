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

/// Persists the user's sync credentials and active protocol selection.
/// Secrets (passwords, the Kobo base URL whose path encodes an auth token)
/// live in `KeychainStore`; preferences and non-secret caches (URLs,
/// usernames, activeProtocol, imageURLTemplate) live in `UserDefaults`.
/// Single-server in v1.
public final class AuthStore: Sendable {
    private let keychain: KeychainStore
    // UserDefaults lacks a formal Sendable conformance in Swift 6, but its
    // get/set operations are thread-safe (serialised internally by Foundation).
    // nonisolated(unsafe) opts this property out of actor-isolation checking
    // while keeping the class Sendable.
    private nonisolated(unsafe) let defaults: UserDefaults

    private static let serverURLKey            = "Kios.serverURL"
    private static let usernameKey             = "Kios.username"
    private static let pwAccount               = "password"
    private static let activeProtocolKey       = "Kios.activeProtocol"
    private static let koboImageURLTemplateKey = "Kios.koboImageURLTemplate"
    private static let koboBaseURLAccount      = "koboBaseURL"

    public init(
        keychain: KeychainStore = .init(service: "com.raphi011.kios.credentials"),
        defaults: UserDefaults = .standard
    ) {
        self.keychain = keychain
        self.defaults = defaults
    }

    /// Stores `serverURL`, `username`, and `password`. Replaces any existing
    /// credential.
    public func save(serverURL: URL, username: String, password: String) throws {
        defaults.set(serverURL.absoluteString, forKey: Self.serverURLKey)
        defaults.set(username, forKey: Self.usernameKey)
        try keychain.set(password, account: Self.pwAccount)
    }

    /// Returns the stored credentials, or nil if any of `(serverURL, username,
    /// password)` is missing.
    public func load() throws -> ServerCredentials? {
        guard
            let urlString = defaults.string(forKey: Self.serverURLKey),
            let url = URL(string: urlString),
            let username = defaults.string(forKey: Self.usernameKey),
            let password = try keychain.get(account: Self.pwAccount)
        else { return nil }
        return ServerCredentials(
            serverURL: url,
            basic: .init(username: username, password: password)
        )
    }

    /// Clears all stored credentials.
    public func clear() throws {
        defaults.removeObject(forKey: Self.serverURLKey)
        defaults.removeObject(forKey: Self.usernameKey)
        defaults.removeObject(forKey: Self.activeProtocolKey)
        defaults.removeObject(forKey: Self.koboImageURLTemplateKey)
        try keychain.delete(account: Self.pwAccount)
        try keychain.delete(account: Self.koboBaseURLAccount)
    }

    /// Loads the user's selected sync protocol. Returns `.kosync` if never set
    /// (first-launch default).
    public func loadActiveProtocol() -> SyncProtocol {
        guard let raw = defaults.string(forKey: Self.activeProtocolKey),
              let proto = SyncProtocol(rawValue: raw) else {
            return .kosync
        }
        return proto
    }

    public func saveActiveProtocol(_ proto: SyncProtocol) {
        defaults.set(proto.rawValue, forKey: Self.activeProtocolKey)
    }

    /// Stores Kobo credentials. The base URL goes to the Keychain (contains
    /// the auth token); the imageURLTemplate goes to UserDefaults.
    public func saveKobo(_ creds: KoboCredentials) throws {
        try keychain.set(creds.baseURL.absoluteString, account: Self.koboBaseURLAccount)
        if let tmpl = creds.imageURLTemplate {
            defaults.set(tmpl, forKey: Self.koboImageURLTemplateKey)
        } else {
            defaults.removeObject(forKey: Self.koboImageURLTemplateKey)
        }
    }

    public func loadKobo() throws -> KoboCredentials? {
        guard let urlString = try keychain.get(account: Self.koboBaseURLAccount),
              let url = URL(string: urlString) else { return nil }
        let tmpl = defaults.string(forKey: Self.koboImageURLTemplateKey)
        return KoboCredentials(baseURL: url, imageURLTemplate: tmpl)
    }

    public func clearKobo() throws {
        try keychain.delete(account: Self.koboBaseURLAccount)
        defaults.removeObject(forKey: Self.koboImageURLTemplateKey)
    }
}
