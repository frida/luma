import Foundation
import Security

enum TokenKind: String {
    case github
}

enum TokenStoreError: Error {
    case saveFailed
    case loadFailed
}

enum TokenStore {
    static func save(_ token: String, kind: TokenKind) throws {
        let key = kind.rawValue
        let data = Data(token.utf8)

        let queryDel: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(queryDel as CFDictionary)

        let queryAdd: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemAdd(queryAdd as CFDictionary, nil)
        guard status == errSecSuccess else { throw TokenStoreError.saveFailed }
    }

    static func load(kind: TokenKind) throws -> String? {
        let key = kind.rawValue
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data,
            let token = String(data: data, encoding: .utf8)
        else {
            throw TokenStoreError.loadFailed
        }
        return token
    }

    static func delete(kind: TokenKind) {
        let key = kind.rawValue
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
