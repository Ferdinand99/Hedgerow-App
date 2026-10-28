import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// The three push routes a Hedgerow server (Vigilant Vole, Keen Kestrel, Wise Wren) has:
//   POST   /api/v1/push/devices        { "handle": "hrh_…" }  ->  201 / 200 { "id": 7 }
//   DELETE /api/v1/push/devices/{id}                          ->  204
//   GET    /api/v1/push/events/{ref}                          ->  { "title", "body", "kind", "level", "occurred_at" }
// They accept the connection's own token (a read-only one too). Errors use the kit envelope
// `{"error": {"code": "...", "message": "..."}}`.

public enum PushServerError: Error, Equatable, Sendable {
    /// `409 push_disabled`: the server has no active "Hedgerow app" channel.
    case pushDisabled
    /// `409 too_many_devices`: 16 devices for this user (256 for the server).
    case tooManyDevices
    /// `409 too_many_pending`: devices that no push has reached yet (4 per user, 20 per server).
    case tooManyPending
    /// `429 rate_limited`: too many new handles in the last hour.
    case rateLimited(retryAfter: Int?)
    /// `401`: the token was refused.
    case unauthorized
    /// `403`: the token may not use this route (an older server).
    case forbidden
    /// `404`/`405` on the route itself: an older server without push.
    case notSupported
    /// `404` for a push text that is unknown or older than 24 hours.
    case notFound
    /// `502`, `503`, `504`, a timeout or no connection.
    case unavailable
    /// The address is not allowed for a token (plain http outside the LAN).
    case insecureURL
    /// Anything else: an answer the app does not understand, a refused redirect, a body that is too large.
    case unexpected
}

/// What `POST /api/v1/push/devices` answers.
public struct PushServerDevice: Equatable, Sendable {
    public let id: Int
    /// `201` for a new registration, `200` when the server already had this handle.
    public let isNew: Bool
}

/// The text behind a push. Plain text; the app never reads anything else from it. The server's
/// `title` has the alert emoji, `body` is detail and facts.
public struct PushEvent: Decodable, Equatable, Sendable {
    public let title: String
    public let body: String
    /// `problem`, `recovered`, `reminder`, … (a value this version does not know is kept as it is).
    public let kind: String?
    /// `critical`, `warning`, `ok` or `info`.
    public let level: String?
    public let occurredAt: Date?

    public init(title: String, body: String, kind: String? = nil, level: String? = nil, occurredAt: Date? = nil) {
        self.title = title
        self.body = body
        self.kind = kind
        self.level = level
        self.occurredAt = occurredAt
    }

    enum CodingKeys: String, CodingKey {
        case title, body, kind, level
        case occurredAt = "occurred_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        body = try container.decode(String.self, forKey: .body)
        kind = try? container.decodeIfPresent(String.self, forKey: .kind)
        level = try? container.decodeIfPresent(String.self, forKey: .level)
        // A time that cannot be read is no time; the text is what matters.
        let text = try? container.decodeIfPresent(String.self, forKey: .occurredAt)
        occurredAt = text.flatMap(Self.parseDate)
    }

    private static func parseDate(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }
}

/// One connection's push routes, with the connection's token. Same rules as every other call to a
/// server: https or a LAN host, a redirect only within the same host, a small response cap.
public struct PushServerClient: Sendable {
    /// The answers are a few hundred bytes (a text of 4000 characters at most, escaped).
    static let maxResponseBytes = 64 * 1024
    static let maxRequestBytes = 1024
    static let devicesPath = "/api/v1/push/devices"
    static let eventsPath = "/api/v1/push/events"

    let baseURL: URL
    private let token: String
    private let transport: any HTTPTransport

    public init(baseURL: URL, token: String, session: URLSession = HedgerowHTTP.defaultSession) {
        self.init(baseURL: baseURL, token: token, transport: URLSessionTransport(session: session))
    }

    init(baseURL: URL, token: String, transport: any HTTPTransport) {
        self.baseURL = baseURL
        self.token = token
        self.transport = transport
    }

    private struct RegisterBody: Encodable {
        let handle: String
    }

    private struct DeviceReply: Decodable {
        let id: Int
    }

    /// Gives the server a handle. The same handle again is `200` with the same id.
    public func register(handle: String) async throws -> PushServerDevice {
        // Nothing but a well-formed handle goes out (the server takes `hrh_` and 20 to 100 more characters).
        guard PigeonClient.isWellFormedID(handle, prefix: "hrh_"), handle.utf8.count <= 104,
              let body = try? JSONEncoder().encode(RegisterBody(handle: handle)),
              body.count <= Self.maxRequestBytes
        else { throw PushServerError.unexpected }
        let reply = try await send("POST", Self.devicesPath, body: body)
        guard reply.status == 200 || reply.status == 201 else { throw Self.error(for: reply, route: .register) }
        guard let device = try? JSONDecoder().decode(DeviceReply.self, from: reply.data), device.id > 0 else {
            throw PushServerError.unexpected
        }
        return PushServerDevice(id: device.id, isNew: reply.status == 201)
    }

    /// Takes the registration down. One that is already gone (`404`) counts as removed.
    public func unregister(deviceId: Int) async throws {
        guard deviceId > 0 else { throw PushServerError.unexpected }
        let reply = try await send("DELETE", Self.devicesPath + "/\(deviceId)", body: nil)
        if (200..<300).contains(reply.status) || reply.status == 404 { return }
        throw Self.error(for: reply, route: .other)
    }

    /// The text behind a push. `ref` is a lookup key and nothing else; one that is not (a path, a
    /// URL) is never sent. `timeout` is the request's own limit.
    public func event(ref: String, timeout: TimeInterval = 15) async throws -> PushEvent {
        guard isLookupKey(ref) else { throw PushServerError.unexpected }
        let reply = try await send("GET", Self.eventsPath + "/" + ref, body: nil, timeout: timeout)
        guard (200..<300).contains(reply.status) else { throw Self.error(for: reply, route: .event) }
        guard let event = try? JSONDecoder().decode(PushEvent.self, from: reply.data) else {
            throw PushServerError.unexpected
        }
        return event
    }

    // MARK: Plumbing

    private func send(
        _ method: String, _ path: String, body: Data?, timeout: TimeInterval = 15
    ) async throws -> HedgerowHTTP.Reply {
        let http = HedgerowHTTP(token: token, transport: transport)
        do {
            return try await http.exchange(
                method, path, base: baseURL, body: body, maxBytes: Self.maxResponseBytes, timeout: timeout
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as HedgerowError {
            switch error {
            case .unreachable: throw PushServerError.unavailable
            case .insecureURL: throw PushServerError.insecureURL
            default: throw PushServerError.unexpected
            }
        }
    }

    private enum Route {
        case register, event, other
    }

    private struct Envelope: Decodable {
        struct Detail: Decodable {
            let code: String?
        }
        let error: Detail?
    }

    private static func code(in data: Data) -> String? {
        (try? JSONDecoder().decode(Envelope.self, from: data))?.error?.code
    }

    private static func error(for reply: HedgerowHTTP.Reply, route: Route) -> PushServerError {
        switch reply.status {
        case 409:
            switch code(in: reply.data) {
            case "push_disabled": .pushDisabled
            case "too_many_devices": .tooManyDevices
            case "too_many_pending": .tooManyPending
            default: .unexpected
            }
        case 429: .rateLimited(retryAfter: reply.retryAfter)
        case 401: .unauthorized
        case 403: .forbidden
        case 404: route == .event ? .notFound : (route == .register ? .notSupported : .notFound)
        case 405: route == .register ? .notSupported : .unexpected
        case 502, 503, 504: .unavailable
        // A redirect that the rules refused (to another host or scheme) ends up here as well.
        default: .unexpected
        }
    }
}
