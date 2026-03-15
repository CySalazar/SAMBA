import Foundation
import Security

struct KeychainService {
    private static let legacyService = "com.smb-mount-manager"
    private static let smbPort: Int = 445

    static func savePassword(_ password: String, for connection: SMBConnection) {
        let normalizedServer = normalize(connection.serverAddress)
        let normalizedUsername = normalize(connection.username)
        let data = Data(password.utf8)

        let query = sharedCredentialQuery(server: normalizedServer, username: normalizedUsername)
        SecItemDelete(query as CFDictionary)

        let addQuery: [String: Any] = query.merging([
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]) { _, new in
            new
        }

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecSuccess {
            LoggingService.shared.record(.info, category: .keychain, message: "Stored shared SMB credential for \(normalizedUsername)@\(normalizedServer)")
            deleteLegacyPassword(for: connection.id)
        } else {
            LoggingService.shared.record(.error, category: .keychain, message: "Failed to store shared SMB credential for \(normalizedUsername)@\(normalizedServer): \(status)")
        }
    }

    static func loadPassword(for connection: SMBConnection) -> String? {
        let normalizedServer = normalize(connection.serverAddress)
        let normalizedUsername = normalize(connection.username)

        if let sharedPassword = loadSharedPassword(server: normalizedServer, username: normalizedUsername) {
            LoggingService.shared.record(.debug, category: .keychain, message: "Loaded shared SMB credential for \(normalizedUsername)@\(normalizedServer)")
            return sharedPassword
        }

        guard let legacyPassword = loadLegacyPassword(for: connection.id) else {
            return nil
        }

        LoggingService.shared.record(.info, category: .keychain, message: "Migrating legacy credential to shared SMB credential for \(normalizedUsername)@\(normalizedServer)")
        savePassword(legacyPassword, for: connection)
        return legacyPassword
    }

    static func deletePassword(for connection: SMBConnection, remainingConnections: [SMBConnection]) {
        deleteLegacyPassword(for: connection.id)

        let normalizedServer = normalize(connection.serverAddress)
        let normalizedUsername = normalize(connection.username)

        let hasOtherConnectionsUsingCredential = remainingConnections.contains { candidate in
            candidate.id != connection.id &&
            normalize(candidate.serverAddress) == normalizedServer &&
            normalize(candidate.username) == normalizedUsername
        }

        guard hasOtherConnectionsUsingCredential == false else {
            LoggingService.shared.record(.debug, category: .keychain, message: "Preserved shared SMB credential for \(normalizedUsername)@\(normalizedServer) because it is still used by another connection")
            return
        }

        let status = SecItemDelete(sharedCredentialQuery(server: normalizedServer, username: normalizedUsername) as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
            LoggingService.shared.record(.info, category: .keychain, message: "Deleted shared SMB credential for \(normalizedUsername)@\(normalizedServer)")
        } else {
            LoggingService.shared.record(.warning, category: .keychain, message: "Failed to delete shared SMB credential for \(normalizedUsername)@\(normalizedServer): \(status)")
        }
    }

    private static func loadSharedPassword(server: String, username: String) -> String? {
        var result: AnyObject?
        let query = sharedCredentialQuery(server: server, username: username).merging([
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]) { _, new in
            new
        }

        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecItemNotFound {
                LoggingService.shared.record(.warning, category: .keychain, message: "Unable to load shared SMB credential for \(username)@\(server): \(status)")
            }
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    private static func sharedCredentialQuery(server: String, username: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: server,
            kSecAttrAccount as String: username,
            kSecAttrProtocol as String: kSecAttrProtocolSMB,
            kSecAttrPort as String: smbPort,
            kSecAttrAuthenticationType as String: kSecAttrAuthenticationTypeDefault
        ]
    }

    private static func loadLegacyPassword(for connectionID: UUID) -> String? {
        let account = connectionID.uuidString
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecItemNotFound {
                LoggingService.shared.record(.warning, category: .keychain, message: "Unable to load legacy password for connection \(account): \(status)")
            }
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    private static func deleteLegacyPassword(for connectionID: UUID) {
        let account = connectionID.uuidString
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyService,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
            LoggingService.shared.record(.debug, category: .keychain, message: "Deleted legacy password entry for connection \(account)")
        } else {
            LoggingService.shared.record(.warning, category: .keychain, message: "Failed to delete legacy password entry for connection \(account): \(status)")
        }
    }

    private static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
