import Foundation
import Security

/// Minimal Keychain wrapper for storing small boolean-equivalent values as
/// single-byte Data under kSecClassGenericPassword.
///
/// Items are stored with kSecAttrAccessibleWhenUnlockedThisDeviceOnly so they
/// cannot be backed up to iCloud or migrated to another device — appropriate
/// for security-gate flags.  iCloud Keychain sync is intentionally omitted.
enum KeychainHelper {
    // MARK: - Errors

    enum KeychainError: Error {
        /// SecItem returned a status other than errSecSuccess / errSecItemNotFound.
        case secError(OSStatus)
    }

    // MARK: - Core API

    /// Reads the Data stored at (service, account).
    ///
    /// - Returns: `nil` when the item does not exist (errSecItemNotFound).
    /// - Throws: `KeychainError.secError` for any other Security framework error.
    static func read(service: String, account: String) throws -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.secError(status)
        }
    }

    /// Writes (or overwrites) the Data at (service, account).
    ///
    /// - Throws: `KeychainError.secError` on failure.
    static func write(service: String, account: String, data: Data) throws {
        let attributes: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData: data
        ]

        // Try adding first; if the item already exists, update it.
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            let query: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: account
            ]
            let update: [CFString: Any] = [kSecValueData: data]
            let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainError.secError(updateStatus)
            }
        } else if addStatus != errSecSuccess {
            throw KeychainError.secError(addStatus)
        }
    }

    /// Deletes the item at (service, account).  Succeeds silently if the item
    /// does not exist.
    ///
    /// - Throws: `KeychainError.secError` on failure (other than not-found).
    static func delete(service: String, account: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.secError(status)
        }
    }

    // MARK: - Bool convenience

    /// Reads a Bool encoded as a single byte (0x00 = false, any other = true).
    /// Returns `nil` when no item exists.
    static func readBool(service: String, account: String) throws -> Bool? {
        guard let data = try read(service: service, account: account) else { return nil }
        return data.first != 0x00
    }

    /// Writes a Bool as a single byte (0x00 = false, 0x01 = true).
    static func writeBool(service: String, account: String, value: Bool) throws {
        let byte: UInt8 = value ? 0x01 : 0x00
        try write(service: service, account: account, data: Data([byte]))
    }
}
