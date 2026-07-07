import Foundation
import Security

enum KeychainStorage {
    enum Key: String, CaseIterable {
        case elevenLabsAPIKey = "elevenlabsApiKey"
        case openRouterAPIKey = "openrouterApiKey"
    }

    private static let service = "com.czapiewski.whispernote"

    static func string(for key: Key) -> String {
        var query = baseQuery(for: key)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return ""
        }

        return value
    }

    static func set(_ value: String, for key: Key) throws {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedValue.isEmpty else {
            try delete(key)
            return
        }

        guard let data = trimmedValue.data(using: .utf8) else { return }

        let query = baseQuery(for: key)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if updateStatus == errSecSuccess {
            return
        }

        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.unhandledStatus(updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.unhandledStatus(addStatus)
        }
    }

    static func migrateLegacyAPIKeysFromUserDefaults() {
        let defaults = UserDefaults.standard

        for key in Key.allCases {
            let legacyValue = defaults.string(forKey: key.rawValue) ?? ""
            if !legacyValue.isEmpty && string(for: key).isEmpty {
                try? set(legacyValue, for: key)
            }
            defaults.removeObject(forKey: key.rawValue)
        }
    }

    private static func delete(_ key: Key) throws {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandledStatus(status)
        }
    }

    private static func baseQuery(for key: Key) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            // ponytail: without this, macOS targets the legacy file-based login
            // keychain, which prompts for the login password on every untrusted
            // access — annoying on unsigned/ad-hoc dev builds whose signature
            // changes every rebuild. Data Protection Keychain trusts by
            // code-signing identity instead, so no interactive prompt.
            kSecUseDataProtectionKeychain as String: true
        ]
    }
}

enum KeychainError: LocalizedError {
    case unhandledStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unhandledStatus(let status):
            return "Keychain operation failed with status \(status)."
        }
    }
}
