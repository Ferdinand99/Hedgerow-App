import Foundation
#if canImport(Security)
import Security
#endif

/// Where API tokens live. Tokens never go anywhere else: not in the connections file,
/// not in UserDefaults, not in logs.
public protocol TokenVault: Sendable {
    func save(_ token: String, for id: UUID) throws
    func token(for id: UUID) throws -> String?
    /// Deleting a token that is not there is not an error.
    func delete(for id: UUID) throws
}

/// For tests and platforms without the Keychain (Linux).
public final class InMemoryVault: TokenVault, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [UUID: String] = [:]

    public init() {}

    public var isEmpty: Bool {
        lock.withLock { tokens.isEmpty }
    }

    public func save(_ token: String, for id: UUID) throws {
        lock.withLock { tokens[id] = token }
    }

    public func token(for id: UUID) throws -> String? {
        lock.withLock { tokens[id] }
    }

    public func delete(for id: UUID) throws {
        _ = lock.withLock { tokens.removeValue(forKey: id) }
    }
}

#if canImport(Security)
public struct KeychainError: Error, Equatable, Sendable {
    public let status: OSStatus
}

/// Generic-password items, one per connection, readable only while the device is unlocked,
/// never migrated to another device and never synchronised through iCloud.
public struct KeychainVault: TokenVault {
    public let service: String
    /// The Keychain access group the items live in (the app target's `keychain-access-groups`
    /// entry, with the team prefix resolved), so widgets in the same group can read them.
    /// `nil`: the app's default group, which is the first entry of its entitlement.
    public let accessGroup: String?

    public init(service: String = "tools.hedgerow.app.tokens", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    private func baseQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: false,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    private func query(for id: UUID) -> [String: Any] {
        baseQuery().merging([kSecAttrAccount as String: id.uuidString]) { $1 }
    }

    public func save(_ token: String, for id: UUID) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        var status = SecItemUpdate(query(for: id) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query(for: id).merging(attributes) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func token(for id: UUID) throws -> String? {
        var request = query(for: id)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        guard let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func delete(for id: UUID) throws {
        let status = SecItemDelete(query(for: id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    /// Removes every token this vault holds. Used when the connection list is reset, because
    /// the ids that would let `delete(for:)` find the tokens are gone with the list.
    public func deleteAll() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }
}
#endif
