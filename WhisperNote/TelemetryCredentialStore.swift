import Foundation
import Security

/// Keeps the webhook header credential out of UserDefaults and the telemetry queue.
/// Implementations must never log the credential or include it in user-visible errors.
protocol TelemetryCredentialStore: Sendable {
    func readToken() throws -> String?
    func saveToken(_ token: String) throws
    func deleteToken() throws
}

enum TelemetryCredentialStoreError: Error, Equatable, Sendable {
    case unavailable
}

final class KeychainTelemetryCredentialStore: TelemetryCredentialStore, @unchecked Sendable {
    private static let service = "com.czapiewski.whispernote.telemetry"
    private static let account = "webhook-header-token"

    func readToken() throws -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: Self.account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else {
            throw TelemetryCredentialStoreError.unavailable
        }
        return token
    }

    func saveToken(_ token: String) throws {
        let data = Data(token.utf8)
        let match: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: Self.account
        ]
        let attributes: [CFString: Any] = [kSecValueData: data]
        let updateStatus = SecItemUpdate(match as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var add = match
            add[kSecValueData] = data
            guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else {
                throw TelemetryCredentialStoreError.unavailable
            }
        } else if updateStatus != errSecSuccess {
            throw TelemetryCredentialStoreError.unavailable
        }
    }

    func deleteToken() throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: Self.account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TelemetryCredentialStoreError.unavailable
        }
    }
}
