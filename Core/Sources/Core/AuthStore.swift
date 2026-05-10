import Foundation

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

/// Persists the user's server URL + username in `UserDefaults` and the
/// password in `KeychainStore`. Single-server in v1.
public final class AuthStore: Sendable {
    private let keychain: KeychainStore
    // UserDefaults lacks a formal Sendable conformance in Swift 6, but its
    // get/set operations are thread-safe (serialised internally by Foundation).
    // nonisolated(unsafe) opts this property out of actor-isolation checking
    // while keeping the class Sendable.
    private nonisolated(unsafe) let defaults: UserDefaults

    private static let serverURLKey = "iOSReader.serverURL"
    private static let usernameKey  = "iOSReader.username"
    private static let pwAccount    = "password"

    public init(
        keychain: KeychainStore = .init(service: "me.iosreader.credentials"),
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
        try keychain.delete(account: Self.pwAccount)
    }
}
