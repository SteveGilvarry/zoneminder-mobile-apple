import Foundation
import Security

public struct StoredSession: Codable, Equatable {
    public let baseURL: URL
    public let accessToken: String
    public let refreshToken: String

    public init(baseURL: URL, accessToken: String, refreshToken: String) {
        self.baseURL = baseURL
        self.accessToken = accessToken
        self.refreshToken = refreshToken
    }
}

/// Credentials persisted on-device so the app can silently re-authenticate when the (deliberately
/// short-lived) refresh token expires — the backend is a stateless REST API and keeps no sessions.
public struct StoredCredentials: Codable, Equatable, Sendable {
    public let username: String
    public let password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }
}

public protocol TokenStore: Sendable {
    func load() throws -> StoredSession?
    func save(_ session: StoredSession) throws
    func clear() throws
    func saveCredentials(_ credentials: StoredCredentials) throws
    func loadCredentials() throws -> StoredCredentials?
}

// Default no-op credential storage so lightweight conformers (e.g. test in-memory stores) don't
// have to implement persistence they don't need.
public extension TokenStore {
    func saveCredentials(_ credentials: StoredCredentials) throws {}
    func loadCredentials() throws -> StoredCredentials? { nil }
}

public final class KeychainTokenStore: TokenStore, @unchecked Sendable {
    private let service = "com.zoneminder.mobile.session"
    private let sessionAccount = "default"
    private let credentialsAccount = "credentials"

    public init() {}

    public func load() throws -> StoredSession? {
        try loadItem(account: sessionAccount).map { try JSONDecoder().decode(StoredSession.self, from: $0) }
    }

    public func save(_ session: StoredSession) throws {
        try saveItem(try JSONEncoder().encode(session), account: sessionAccount)
    }

    public func saveCredentials(_ credentials: StoredCredentials) throws {
        try saveItem(try JSONEncoder().encode(credentials), account: credentialsAccount)
    }

    public func loadCredentials() throws -> StoredCredentials? {
        try loadItem(account: credentialsAccount).map { try JSONDecoder().decode(StoredCredentials.self, from: $0) }
    }

    public func clear() throws {
        try deleteItem(account: sessionAccount)
        try deleteItem(account: credentialsAccount)
    }

    // MARK: - Keychain primitives

    private func loadItem(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw KeychainError(status) }
        return data
    }

    private func saveItem(_ data: Data, account: String) throws {
        try deleteItem(account: account)
        var query = baseQuery(account: account)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status) }
    }

    private func deleteItem(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound { throw KeychainError(status) }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

public struct KeychainError: Error, CustomStringConvertible {
    public let status: OSStatus
    public init(_ status: OSStatus) { self.status = status }
    public var description: String { "Keychain error: \(status)" }
}
