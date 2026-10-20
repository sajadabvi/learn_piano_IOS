import Foundation
import Security

/// Errors from the Keychain wrapper. `status` is the Security framework's `OSStatus`.
enum SettingsKeychainError: Error, LocalizedError, Equatable {
    /// The stored item could not be decoded as UTF-8 text.
    case invalidData
    /// The Security framework returned an unexpected status.
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidData:
            return "The saved key could not be read."
        case .unexpectedStatus(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
            return "Keychain error: \(message)"
        }
    }
}

/// Minimal generic-password Keychain store for one secret string.
///
/// The app keeps the learner's Claude API key under service `com.sajadabvi.LearnPiano`, account
/// `anthropic-api-key` (`SettingsKeychain.anthropicAPIKey`). The Import module reads the same item, either through
/// this type (`SettingsKeychain.anthropicAPIKey.read()`) or directly with `SecItemCopyMatching` using
/// `kSecClassGenericPassword` + those two attributes. Items are stored with
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, so they never leave the device through backups.
struct SettingsKeychain: Sendable, Hashable {
    /// Keychain service attribute.
    let service: String
    /// Keychain account attribute.
    let account: String

    static let appService = "com.sajadabvi.LearnPiano"
    static let anthropicAPIKeyAccount = "anthropic-api-key"

    /// The Claude API key item shared by Settings (writes) and Import (reads).
    static let anthropicAPIKey = SettingsKeychain(service: appService, account: anthropicAPIKeyAccount)

    init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// The stored string, or nil when there is no item.
    func read() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let string = String(data: data, encoding: .utf8) else {
                throw SettingsKeychainError.invalidData
            }
            return string
        case errSecItemNotFound:
            return nil
        default:
            throw SettingsKeychainError.unexpectedStatus(status)
        }
    }

    /// Stores `value`, replacing any existing item.
    func write(_ value: String) throws {
        let data = Data(value.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = baseQuery
            for (key, value) in attributes { addQuery[key] = value }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw SettingsKeychainError.unexpectedStatus(addStatus) }
        default:
            throw SettingsKeychainError.unexpectedStatus(updateStatus)
        }
    }

    /// Removes the item. Deleting a missing item is not an error.
    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SettingsKeychainError.unexpectedStatus(status)
        }
    }
}
