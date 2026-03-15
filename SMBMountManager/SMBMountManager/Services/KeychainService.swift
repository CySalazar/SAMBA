import Foundation
import Security

struct KeychainService {
    private static let service = "com.smb-mount-manager"

    static func savePassword(_ password: String, for connectionID: UUID) {
        let account = connectionID.uuidString
        let data = Data(password.utf8)

        // Delete existing item first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Add new item
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecSuccess {
            LoggingService.shared.record(.info, category: .keychain, message: "Stored password for connection \(account)")
        } else {
            LoggingService.shared.record(.error, category: .keychain, message: "Failed to store password for connection \(account): \(status)")
        }
    }

    static func loadPassword(for connectionID: UUID) -> String? {
        let account = connectionID.uuidString
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecItemNotFound {
                LoggingService.shared.record(.warning, category: .keychain, message: "Unable to load password for connection \(account): \(status)")
            }
            return nil
        }
        LoggingService.shared.record(.debug, category: .keychain, message: "Loaded password for connection \(account)")
        return String(data: data, encoding: .utf8)
    }

    static func deletePassword(for connectionID: UUID) {
        let account = connectionID.uuidString
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
            LoggingService.shared.record(.info, category: .keychain, message: "Deleted password for connection \(account)")
        } else {
            LoggingService.shared.record(.warning, category: .keychain, message: "Failed to delete password for connection \(account): \(status)")
        }
    }
}
