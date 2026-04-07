import Foundation

public protocol TokenStore: Sendable {
    func get(service: String, account: String) async throws -> String?
    func set(service: String, account: String, token: String) async throws
    func delete(service: String, account: String) async throws
}

#if canImport(Security)
import Security

public struct KeychainTokenStore: TokenStore {
    public init() {}

    public func get(service: String, account: String) async throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status == errSecItemNotFound { return nil }
            throw TokenStoreError.keychainError(status)
        }
        return String(data: data, encoding: .utf8)
    }

    public func set(service: String, account: String, token: String) async throws {
        let data = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw TokenStoreError.keychainError(status)
        }
    }

    public func delete(service: String, account: String) async throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TokenStoreError.keychainError(status)
        }
    }
}
#endif

public struct FileTokenStore: TokenStore {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func fileURL(service: String, account: String) -> URL {
        directory.appendingPathComponent("\(service).\(account).token")
    }

    public func get(service: String, account: String) async throws -> String? {
        let url = fileURL(service: service, account: account)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func set(service: String, account: String, token: String) async throws {
        try Data(token.utf8).write(to: fileURL(service: service, account: account), options: .atomic)
    }

    public func delete(service: String, account: String) async throws {
        try? FileManager.default.removeItem(at: fileURL(service: service, account: account))
    }
}

public enum TokenStoreError: Error {
    #if canImport(Security)
    case keychainError(OSStatus)
    #endif
    case unavailable
}
