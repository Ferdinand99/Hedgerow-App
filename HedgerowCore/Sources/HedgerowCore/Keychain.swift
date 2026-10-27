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

    public init(service: String = "tools.hedgerow.app.tokens") {
        self.service = service
    }

    private func query(for id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecAttrSynchronizable as String: false,
        ]
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
}
#endif
