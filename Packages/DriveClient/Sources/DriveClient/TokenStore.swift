import Foundation
import Security

public protocol TokenStore: Sendable {
    func loadRefreshToken() throws -> String?
    func save(refreshToken: String) throws
    func clear() throws
}

public final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?

    public init(initial: String? = nil) {
        self.token = initial
    }

    public func loadRefreshToken() throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return token
    }

    public func save(refreshToken: String) throws {
        lock.lock(); defer { lock.unlock() }
        token = refreshToken
    }

    public func clear() throws {
        lock.lock(); defer { lock.unlock() }
        token = nil
    }
}

public struct KeychainTokenStore: TokenStore {
    public static let defaultService = "com.dimroom.DriveClient"
    public static let defaultAccount = "google.refresh_token"

    private let service: String
    private let account: String

    public init(service: String = defaultService, account: String = defaultAccount) {
        self.service = service
        self.account = account
    }

    public func loadRefreshToken() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
                return nil
            }
            return token
        case errSecItemNotFound:
            return nil
        default:
            throw DriveClientError.keychainFailure(status)
        }
    }

    public func save(refreshToken: String) throws {
        let data = Data(refreshToken.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw DriveClientError.keychainFailure(addStatus)
            }
            return
        }
        throw DriveClientError.keychainFailure(updateStatus)
    }

    public func clear() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DriveClientError.keychainFailure(status)
        }
    }
}
