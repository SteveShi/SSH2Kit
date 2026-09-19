import Foundation
import Security

public struct KeychainStore {
    public static let service = "MacSSH"

    /// Passwords stay on this device and require an unlocked session.
    /// Without `synchronizable: false` the item could follow the user's
    /// iCloud Keychain to other machines; without the accessibility hint
    /// the system default may be broader than intended.
    private static var protectionAttributes: [String: Any] {
        [
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: false
        ]
    }

    public static func loadPassword(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public static func savePassword(_ password: String, account: String) -> Bool {
        let data = Data(password.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false
        ]

        let attributes: [String: Any] = protectionAttributes.merging([
            kSecValueData as String: data
        ]) { _, new in new }

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var newItem = query
            newItem.merge(attributes) { _, new in new }
            return SecItemAdd(newItem as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    public static func deletePassword(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false
        ]
        _ = SecItemDelete(query as CFDictionary)
    }
}

