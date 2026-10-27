import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Security)
import Security
#endif

// Postal Pigeon: the push relay. The app registers this device's APNs token with it and keeps
// the device id and the manage key it gets back. Servers (Vigilant Vole, Keen Kestrel, Wise Wren)
// get their own handles later; nothing here talks to them.
// API: Hedgerow-Relay docs/api.md, sections "Conventions" and "Devices and handles".

/// `sandbox` for builds run from Xcode, `production` for TestFlight and the App Store.
public enum PigeonEnvironment: String, Sendable, Equatable, Codable {
    case sandbox
    case production
}

/// What the relay hands out when a device registers. `deviceId` (`hrd_…`) is not secret;
/// `manageKey` (`hrm_…`) is, and is never logged or shown.
public struct PigeonRegistration: Codable, Sendable, Equatable {
    public let deviceId: String
    public let manageKey: String

    public init(deviceId: String, manageKey: String) {
        self.deviceId = deviceId
        self.manageKey = manageKey
    }

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case manageKey = "manage_key"
    }
}

// Printing a registration or a record (a log line, a test failure) shows the device id only.
extension PigeonRegistration: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "PigeonRegistration(deviceId: \(deviceId), manageKey: <hidden>)" }
    public var debugDescription: String { description }
}

public enum PigeonError: Error, Equatable, Sendable {
    /// `404`: the relay has no such device any more. Register again.
    case gone
    /// `429`: wait `Retry-After` seconds (when the relay said how long).
    case rateLimited(retryAfter: Int?)
    /// `503` and friends, or no connection: try again later.
    case unavailable
    /// `401`: the manage key was refused.
    case invalidCredentials
    /// The relay address is not https, so nothing was sent.
    case insecureURL
    /// Anything else: an answer the app does not understand, a redirect, an oversized body.
    case unexpected
}

// MARK: - Client

/// One request per call, over the same transport and safety rules as the other clients:
/// `https` only, no redirect to another host or scheme, a small response cap.
public struct PigeonClient: Sendable {
    /// The one relay the app uses.
    public static let relayURL = URL(string: "https://pigeon.hedgerow.tools")!
    /// Answers are a few dozen bytes; 64 KiB is plenty.
    static let maxResponseBytes = 64 * 1024
    /// The relay refuses request bodies over 2 KiB.
    static let maxRequestBytes = 2 * 1024
    static let devicesPath = "/v1/devices"

    let baseURL: URL
    private let transport: any HTTPTransport

    public init(session: URLSession = HedgerowHTTP.defaultSession) {
        self.init(baseURL: Self.relayURL, transport: URLSessionTransport(session: session))
    }

    init(baseURL: URL, transport: any HTTPTransport) {
        self.baseURL = baseURL
        self.transport = transport
    }

    private struct RegisterBody: Encodable {
        let app: String
        let environment: String
        let token: String
    }

    private struct UpdateBody: Encodable {
        let token: String?
        let environment: String?
    }

    /// `POST /v1/devices`. A record for the same token is replaced by the relay.
    public func register(
        app: String = "hedgerow", environment: PigeonEnvironment, token: Data
    ) async throws -> PigeonRegistration {
        let body = try encode(RegisterBody(app: app, environment: environment.rawValue, token: token.hexString))
        let reply = try await send("POST", Self.devicesPath, manageKey: nil, body: body)
        guard (200..<300).contains(reply.status) else { throw Self.error(for: reply, gone: .unexpected) }
        guard let registration = try? JSONDecoder().decode(PigeonRegistration.self, from: reply.data),
              Self.isWellFormedID(registration.deviceId, prefix: "hrd_"),
              Self.isWellFormedID(registration.manageKey, prefix: "hrm_")
        else { throw PigeonError.unexpected }
        return registration
    }

    /// `PUT /v1/devices/{id}`: a new token, a new environment, or just a keep-alive (both `nil`).
    /// `404` is `PigeonError.gone`: register again.
    public func update(
        _ registration: PigeonRegistration, token: Data? = nil, environment: PigeonEnvironment? = nil
    ) async throws {
        guard Self.isWellFormedID(registration.deviceId, prefix: "hrd_"),
              Self.isWellFormedID(registration.manageKey, prefix: "hrm_")
        else { throw PigeonError.unexpected }
        let body = try encode(UpdateBody(token: token?.hexString, environment: environment?.rawValue))
        let reply = try await send(
            "PUT", Self.devicesPath + "/" + registration.deviceId, manageKey: registration.manageKey, body: body
        )
        guard (200..<300).contains(reply.status) else { throw Self.error(for: reply, gone: .gone) }
    }

    /// `DELETE /v1/devices/{id}`. A record that is already gone counts as removed.
    public func remove(_ registration: PigeonRegistration) async throws {
        guard Self.isWellFormedID(registration.deviceId, prefix: "hrd_"),
              Self.isWellFormedID(registration.manageKey, prefix: "hrm_")
        else { throw PigeonError.unexpected }
        let reply = try await send(
            "DELETE", Self.devicesPath + "/" + registration.deviceId, manageKey: registration.manageKey, body: nil
        )
        if (200..<300).contains(reply.status) || reply.status == 404 { return }
        throw Self.error(for: reply, gone: .gone)
    }

    // MARK: Plumbing

    private func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value), data.count <= Self.maxRequestBytes else {
            throw PigeonError.unexpected
        }
        return data
    }

    private func send(
        _ method: String, _ path: String, manageKey: String?, body: Data?
    ) async throws -> HedgerowHTTP.Reply {
        // The relay is reached over https only, even though the shared rules also let a LAN host
        // use plain http.
        guard baseURL.scheme?.lowercased() == "https" else { throw PigeonError.insecureURL }
        let http = HedgerowHTTP(token: manageKey, transport: transport)
        do {
            return try await http.exchange(
                method, path, base: baseURL, body: body, alwaysJSON: true, maxBytes: Self.maxResponseBytes
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as HedgerowError {
            switch error {
            case .unreachable: throw PigeonError.unavailable
            case .insecureURL: throw PigeonError.insecureURL
            default: throw PigeonError.unexpected
            }
        }
    }

    /// `gone` is what a `404` means for this call: the record, for `PUT`; nothing sensible for `POST`.
    private static func error(for reply: HedgerowHTTP.Reply, gone: PigeonError) -> PigeonError {
        switch reply.status {
        case 404: gone
        case 401: .invalidCredentials
        case 429: .rateLimited(retryAfter: reply.retryAfter)
        // 503 overloaded; 502 and 504 are a proxy in front of the relay having a bad moment.
        case 502, 503, 504: .unavailable
        // A redirect that the rules refused (to another host or scheme) ends up here as well.
        default: .unexpected
        }
    }

    /// An id or key that is safe to put in a URL path or a header: the prefix and then letters,
    /// digits, `_` and `-`.
    static func isWellFormedID(_ value: String, prefix: String) -> Bool {
        guard value.hasPrefix(prefix), value.count > prefix.count, value.count <= 128 else { return false }
        return value.utf8.allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A)
                || $0 == 0x5F || $0 == 0x2D
        }
    }
}

extension Data {
    /// Lowercase hexadecimal, the way the relay wants an APNs device token.
    public var hexString: String {
        let digits = Array("0123456789abcdef")
        var out = ""
        out.reserveCapacity(count * 2)
        for byte in self {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0F)])
        }
        return out
    }
}

// MARK: - Keep-alive

/// The relay wants a `PUT` on launch, at most once a day (a device it has not heard from in
/// 90 days is deleted). A last-sent time in the future (the clock was set back) counts as due.
public func needsKeepAlive(lastSent: Date?, now: Date) -> Bool {
    guard let lastSent else { return true }
    let age = now.timeIntervalSince(lastSent)
    return age < 0 || age >= 24 * 3600
}

// MARK: - Storage

/// What is kept on this device about the registration: the ids, the APNs token the relay was
/// last given (hex), and when the relay last heard from this device. Kept together so they
/// cannot disagree. Only ever in the Keychain.
public struct PigeonRecord: Codable, Sendable, Equatable {
    public var registration: PigeonRegistration
    public var token: String
    public var lastSent: Date

    public init(registration: PigeonRegistration, token: String, lastSent: Date) {
        self.registration = registration
        self.token = token
        self.lastSent = lastSent
    }
}

extension PigeonRecord: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "PigeonRecord(\(registration), token: <hidden>, lastSent: \(lastSent))" }
    public var debugDescription: String { description }
}

public protocol PigeonStore: Sendable {
    func load() throws -> PigeonRecord?
    func save(_ record: PigeonRecord) throws
    /// Clearing what is not there is not an error.
    func clear() throws
}

/// For tests and platforms without the Keychain (Linux).
public final class InMemoryPigeonStore: PigeonStore, @unchecked Sendable {
    private let lock = NSLock()
    private var record: PigeonRecord?

    public init(_ record: PigeonRecord? = nil) {
        self.record = record
    }

    public func load() throws -> PigeonRecord? { lock.withLock { record } }
    public func save(_ record: PigeonRecord) throws { lock.withLock { self.record = record } }
    public func clear() throws { lock.withLock { record = nil } }
}

private func encodeRecord(_ record: PigeonRecord) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(record)
}

/// `nil` for data that is not a record (a damaged item): the next save replaces it.
private func decodeRecord(_ data: Data) -> PigeonRecord? {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(PigeonRecord.self, from: data)
}

#if canImport(Security)
/// One generic-password item. It is readable after the first unlock (the token callback can
/// arrive while the phone is locked), never leaves this device and is never synchronised
/// through iCloud. Kept apart from the connection tokens (own service name), so resetting the
/// connections does not touch it.
public struct KeychainPigeonStore: PigeonStore {
    public let service: String
    public let accessGroup: String?
    private let account = "registration"

    public init(service: String = "tools.hedgerow.app.pigeon", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    private func query() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    public func load() throws -> PigeonRecord? {
        var request = query()
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return (result as? Data).flatMap(decodeRecord)
    }

    public func save(_ record: PigeonRecord) throws {
        let data = try encodeRecord(record)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(query() as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query().merging(attributes) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func clear() throws {
        let status = SecItemDelete(query() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }
}
#endif

// MARK: - Registrar

/// Keeps this device's registration with the relay in step with the APNs token. One call at a
/// time (it is an actor, and the app queues its calls as well).
public actor PigeonRegistrar {
    private let client: PigeonClient
    private let store: any PigeonStore
    private let environment: PigeonEnvironment
    private let now: @Sendable () -> Date

    public init(client: PigeonClient, store: any PigeonStore, environment: PigeonEnvironment) {
        self.init(client: client, store: store, environment: environment, now: { Date() })
    }

    init(
        client: PigeonClient, store: any PigeonStore, environment: PigeonEnvironment,
        now: @escaping @Sendable () -> Date
    ) {
        self.client = client
        self.store = store
        self.environment = environment
        self.now = now
    }

    /// The device id that is stored, if any (it is not secret).
    public func storedDeviceId() -> String? {
        (try? store.load())?.registration.deviceId
    }

    /// APNs gave the app `token`. With nothing stored: register. With a stored registration:
    /// `PUT` when the token changed or the daily keep-alive is due, nothing otherwise. A `404`
    /// (the record is gone) or a refused manage key means registering again, once; the new ids
    /// replace the old ones.
    @discardableResult
    public func apply(token: Data) async throws -> PigeonRegistration {
        let hex = token.hexString
        guard let record = try store.load() else {
            return try await registerAndStore(token: token, hex: hex)
        }
        if record.token == hex, !needsKeepAlive(lastSent: record.lastSent, now: now()) {
            return record.registration
        }
        do {
            try await client.update(record.registration, token: token, environment: environment)
        } catch PigeonError.gone, PigeonError.invalidCredentials {
            return try await registerAndStore(token: token, hex: hex)
        }
        try store.save(PigeonRecord(registration: record.registration, token: hex, lastSent: now()))
        return record.registration
    }

    /// Notifications are off: ask the relay to delete the device, then forget it here. The local
    /// side is cleared even when the relay cannot be reached (the app must say "off" either way;
    /// the relay drops an unheard-from device after 90 days). Returns whether the relay confirmed.
    @discardableResult
    public func disable() async -> Bool {
        guard let record = try? store.load() else {
            try? store.clear()
            return true
        }
        var confirmed = true
        do {
            try await client.remove(record.registration)
        } catch {
            confirmed = false
        }
        try? store.clear()
        return confirmed
    }

    private func registerAndStore(token: Data, hex: String) async throws -> PigeonRegistration {
        let registration = try await client.register(environment: environment, token: token)
        do {
            try store.save(PigeonRecord(registration: registration, token: hex, lastSent: now()))
        } catch {
            // Could not keep the manage key: do not leave a record behind that nobody can remove.
            try? await client.remove(registration)
            throw error
        }
        return registration
    }
}
