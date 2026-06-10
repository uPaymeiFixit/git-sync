import Foundation
import Security

// Tiny wrapper around the Keychain for secrets we never want in
// UserDefaults (GitHub tokens, Bitbucket app passwords). Each secret is
// stored as a generic password keyed by a stable identifier.
enum Keychain {
    private static let service = "com.uPaymeiFixit.GitSyncMenuBar"

    static func set(_ value: String?, for key: String) {
        if let value, !value.isEmpty {
            save(value, key: key)
        } else {
            delete(key: key)
        }
    }

    static func get(_ key: String) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        _ = query.removeValue(forKey: kSecReturnData as String)
        return value
    }

    private static func save(_ value: String, key: String) {
        let data = Data(value.utf8)
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let status = SecItemCopyMatching(baseQuery as CFDictionary, nil)
        if status == errSecSuccess {
            let updates: [String: Any] = [kSecValueData as String: data]
            SecItemUpdate(baseQuery as CFDictionary, updates as CFDictionary)
        } else {
            var add = baseQuery
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    private static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
