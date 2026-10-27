import Foundation
import Observation

/// The Hedgerow products the app can talk to.
public enum ServiceKind: String, Codable, Sendable, CaseIterable {
    case vole
    case kestrel
    case wren

    /// The product name as it appears in the `info.title` of its OpenAPI document.
    var productName: String {
        switch self {
        case .vole: "Vigilant Vole"
        case .kestrel: "Keen Kestrel"
        case .wren: "Wise Wren"
        }
    }

    /// A cheap read-only call a viewer token may make; used to check that a token works.
    var viewerPath: String {
        switch self {
        case .vole: "/api/v1/monitors"
        case .kestrel: "/api/v1/projects"
        case .wren: "/api/v1/servers"
        }
    }
}

/// One saved service: a name, where it lives and which product it is.
/// The token is never part of this value; it lives in the Keychain.
public struct Connection: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public var name: String
    public var baseURL: URL
    public var kind: ServiceKind

    public init(id: UUID = UUID(), name: String, baseURL: URL, kind: ServiceKind) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.kind = kind
    }
}

public enum ConnectionStoreError: Error, Equatable, Sendable {
    case unknownConnection
}

/// The saved connections. The list lives in a JSON file (in the app: the App Group
/// container); each token lives in the `TokenVault`, never in that file.
@MainActor @Observable
public final class ConnectionStore {
    public private(set) var connections: [Connection]

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let vault: any TokenVault
    @ObservationIgnored private let makeHTTP: @Sendable (String?) -> HedgerowHTTP

    /// Reads `fileURL` if it exists. A file that cannot be read is an error, not an empty list,
    /// so the next save never wipes it.
    public convenience init(fileURL: URL, vault: any TokenVault) throws {
        try self.init(fileURL: fileURL, vault: vault) { HedgerowHTTP(token: $0) }
    }

    init(
        fileURL: URL, vault: any TokenVault, makeHTTP: @escaping @Sendable (String?) -> HedgerowHTTP
    ) throws {
        self.fileURL = fileURL
        self.vault = vault
        self.makeHTTP = makeHTTP
        if FileManager.default.fileExists(atPath: fileURL.path) {
            connections = try JSONDecoder().decode([Connection].self, from: Data(contentsOf: fileURL))
        } else {
            connections = []
        }
    }

    /// Detects the product at `url` (the OpenAPI document needs a signed-in user, so the token is
    /// sent from the first request on), checks that `token` is accepted by a viewer call, and only
    /// then stores the token in the vault and the connection in the list. A missing or wrong token
    /// is `.unauthorized`, a token without access is `.forbidden`, a 200 that is not a Hedgerow
    /// document is `.notHedgerow`.
    @discardableResult
    public func add(url: URL, token: String, name: String?) async throws -> Connection {
        // Before anything is sent: a token must never travel over plain http to a public host.
        guard isAllowedBaseURL(url) else { throw HedgerowError.insecureURL }
        let token = try Self.cleaned(token: token)

        let kind = try await ServiceDetector(http: makeHTTP(token)).detect(url)
        try await verify(token: token, kind: kind, at: url)
        // A cancelled or timed-out Add stores nothing: nothing suspends between here and the saves.
        try Task.checkCancellation()

        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let connection = Connection(
            name: trimmedName.isEmpty ? (url.host ?? url.absoluteString) : trimmedName,
            baseURL: url,
            kind: kind
        )
        try vault.save(token, for: connection.id)
        do {
            try persist(connections + [connection])
        } catch {
            try? vault.delete(for: connection.id)
            throw error
        }
        connections.append(connection)
        return connection
    }

    /// Deletes the token first: if that fails the connection stays, so it can be retried
    /// and no token is left behind unseen.
    public func remove(_ id: UUID) throws {
        try vault.delete(for: id)
        guard connections.contains(where: { $0.id == id }) else { return }
        try persist(connections.filter { $0.id != id })
        connections.removeAll { $0.id == id }
    }

    public func replaceToken(_ id: UUID, token: String) throws {
        guard connections.contains(where: { $0.id == id }) else {
            throw ConnectionStoreError.unknownConnection
        }
        try vault.save(Self.cleaned(token: token), for: id)
    }

    /// Checks that `token` is accepted by the saved connection `id`, with the same viewer call
    /// `add` makes (401 is `.unauthorized`, 403 `.forbidden`, a redirect or non-JSON answer
    /// `.notHedgerow`, as in `add`), and stores nothing. For "replace token": verify first, then `replaceToken`.
    public func verifyToken(_ token: String, for id: UUID) async throws {
        guard let connection = connections.first(where: { $0.id == id }) else {
            throw ConnectionStoreError.unknownConnection
        }
        // The saved address was allowed when it was added; check again before a token is sent.
        guard isAllowedBaseURL(connection.baseURL) else { throw HedgerowError.insecureURL }
        try await verify(token: Self.cleaned(token: token), kind: connection.kind, at: connection.baseURL)
    }

    /// Surrounding whitespace removed; empty or containing control characters is refused
    /// (it could never be a valid header value).
    private static func cleaned(token: String) throws -> String {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty,
              !token.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw HedgerowError.unauthorized }
        return token
    }

    /// The token saved for a connection, for building an authenticated client.
    public func token(for id: UUID) throws -> String? {
        try vault.token(for: id)
    }

    private func verify(token: String, kind: ServiceKind, at url: URL) async throws {
        let data = try await makeHTTP(token).getData(kind.viewerPath, from: url)
        // 401/403 have already been thrown. What is left must still look like an API answer.
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []),
              json is [Any] || json is [String: Any]
        else { throw HedgerowError.notHedgerow }
    }

    private func persist(_ list: [Connection]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(list)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }
}
