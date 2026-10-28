import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What the notification extension changes about a notification. Everything here is plain text.
/// A field that is `nil` is left as it came (the generic "Something needs your attention").
public struct NotificationRewrite: Equatable, Sendable {
    public var title: String?
    public var body: String?
    /// The connection the notification belongs to, so one server's notifications group together.
    public var threadIdentifier: String?

    public init(title: String? = nil, body: String? = nil, threadIdentifier: String? = nil) {
        self.title = title
        self.body = body
        self.threadIdentifier = threadIdentifier
    }

    /// The notification stays as the relay sent it.
    public static let unchanged = NotificationRewrite()
}

/// The logic of the Notification Service Extension: from the payload of a push to the text to show.
/// It lives here so it can be tested without a phone; the extension target only calls it.
///
/// What it does, and nothing more:
/// 1. reads the tag from the payload and looks it up in the `PushRegistry` (the app's own record);
/// 2. finds that connection in the saved list and its token in the Keychain;
/// 3. asks that connection's own server for the text behind the `ref`, for at most `limit`;
/// 4. returns the title and the body as plain text.
///
/// Any failure (unknown tag, unknown version, no token, no network, a slow or unhappy server) is
/// `.unchanged` or only the grouping. The extension has about 30 seconds and little memory: one
/// small request, no retries.
public struct NotificationRewriter: Sendable {
    /// The text is cut to what a notification can show anyway.
    static let maxTitle = 300
    static let maxBody = 4000

    private let registry: PushRegistry
    private let connections: @Sendable () -> [Connection]
    private let vault: any TokenVault
    private let limit: Duration
    private let makeClient: @Sendable (Connection, String) -> PushServerClient

    public init(
        registry: PushRegistry, connections: @escaping @Sendable () -> [Connection], vault: any TokenVault,
        limit: Duration = .seconds(10)
    ) {
        self.init(registry: registry, connections: connections, vault: vault, limit: limit) { connection, token in
            PushServerClient(baseURL: connection.baseURL, token: token)
        }
    }

    init(
        registry: PushRegistry, connections: @escaping @Sendable () -> [Connection], vault: any TokenVault,
        limit: Duration, makeClient: @escaping @Sendable (Connection, String) -> PushServerClient
    ) {
        self.registry = registry
        self.connections = connections
        self.vault = vault
        self.limit = limit
        self.makeClient = makeClient
    }

    public func rewrite(_ payload: PushPayload) async -> NotificationRewrite {
        // A later version of the format, or something that is not ours: the generic text stays.
        guard case .v1(let push) = payload, push.kind == .alert else { return .unchanged }
        guard let entry = registry.entry(forTag: push.tag),
              let connection = connections().first(where: { $0.id == entry.connectionId })
        else { return .unchanged }

        let grouping = NotificationRewrite(threadIdentifier: connection.id.uuidString)
        guard let ref = push.ref else { return grouping }
        // A locked phone before its first unlock has no Keychain: the same as no token.
        guard let token = try? vault.token(for: connection.id), !token.isEmpty else { return grouping }

        let client = makeClient(connection, token)
        let seconds = TimeInterval(limit.components.seconds) + TimeInterval(limit.components.attoseconds) / 1e18
        do {
            let event = try await withDeadline(limit) {
                try await client.event(ref: ref, timeout: seconds)
            }
            let title = Self.plainText(event.title, limit: Self.maxTitle, keepNewlines: false)
            let body = Self.plainText(event.body, limit: Self.maxBody, keepNewlines: true)
            guard !title.isEmpty else { return grouping }
            return NotificationRewrite(title: title, body: body, threadIdentifier: connection.id.uuidString)
        } catch {
            return grouping
        }
    }

    /// Text from a server, made safe to show: control characters are dropped (line breaks kept in a
    /// body), surrounding space is trimmed and the length is limited.
    static func plainText(_ text: String, limit: Int, keepNewlines: Bool) -> String {
        var out = String.UnicodeScalarView()
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        for scalar in normalized.unicodeScalars {
            if scalar == "\n" || scalar == "\r" {
                out.append(keepNewlines ? "\n" : " ")
            } else if scalar == "\t" {
                out.append(" ")
            } else if scalar.properties.generalCategory == .control || (scalar.properties.generalCategory == .format
                        && scalar.value != 0x200D) {
                // Control and invisible format characters (bidi overrides included); a joiner stays so emoji hold together.
                continue
            } else {
                out.append(scalar)
            }
        }
        let trimmed = String(out).trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(limit))
    }
}
