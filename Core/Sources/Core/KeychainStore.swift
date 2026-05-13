import Foundation
import Security

/// Generic-password keychain wrapper, scoped by a `service` identifier.
///
/// All items are stored with `kSecAttrAccessibleAfterFirstUnlock`, allowing
/// reads in the background after the device has been unlocked once since
/// boot. Items survive app reinstall on iOS unless the user wipes the device.
public struct KeychainStore: Sendable {

    /// The service identifier scoping all items in this store. Conventionally
    /// a reverse-DNS string like `"com.raphi011.kios.credentials"`.
    public let service: String

    public init(service: String) {
        self.service = service
    }

    /// Errors thrown by `KeychainStore` operations.
    public enum Error: Swift.Error, LocalizedError, Sendable {
        /// An unmapped Security framework status code.
        case unhandled(OSStatus)
        /// Stored bytes could not be decoded as UTF-8.
        case dataCorrupted

        public var errorDescription: String? {
            switch self {
            case .unhandled(let status):
                return "Keychain error \(status): \(SecCopyErrorMessageString(status, nil) as String? ?? "unknown")"
            case .dataCorrupted:
                return "Keychain data could not be decoded as UTF-8."
            }
        }
    }

    /// Stores `value` for `account`, replacing any existing entry.
    public func set(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        // Update-then-add: SecItem* is internally serialized, so this TOCTOU is
        // benign. A racing concurrent first-write surfaces as errSecDuplicateItem;
        // we don't currently retry — production traffic is single-writer.
        let updateStatus = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var newItem = query
            newItem[kSecValueData as String] = data
            newItem[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(newItem as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw Error.unhandled(addStatus) }
        default:
            throw Error.unhandled(updateStatus)
        }
    }

    /// Returns the value for `account`, or `nil` if no entry exists.
    /// Throws on Keychain errors other than "not found".
    public func get(account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw Error.dataCorrupted }
            guard let s = String(data: data, encoding: .utf8) else { throw Error.dataCorrupted }
            return s
        case errSecItemNotFound:
            return nil
        default:
            throw Error.unhandled(status)
        }
    }

    /// Removes any entry for `account`. Idempotent — no-op if missing.
    public func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Error.unhandled(status)
        }
    }
}
