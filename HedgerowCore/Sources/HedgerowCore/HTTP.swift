import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum HedgerowError: Error, Equatable, Sendable {
    /// Something answered, but it is not a Hedgerow product (or not the one expected).
    case notHedgerow
    case unauthorized
    case forbidden
    case unreachable(String)
    case badResponse(Int)
    case tooLarge
    /// Plain `http` to an address outside the LAN, or a URL that cannot be used.
    case insecureURL
}

// MARK: - URL policy

/// `https` anywhere, plain `http` only to hosts on a LAN: loopback, RFC 1918,
/// link-local, `.local`, `.lan`, `.home.arpa`, `.internal`, Tailscale
/// (100.64.0.0/10 and `.ts.net`). Same list as the Wise Wren agent.
public func isAllowedBaseURL(_ url: URL) -> Bool {
    guard url.user == nil, url.password == nil else { return false }
    guard var host = url.host?.lowercased(), !host.isEmpty else { return false }
    switch url.scheme?.lowercased() {
    case "https":
        return true
    case "http":
        if host.hasSuffix(".") { host.removeLast() }
        return isLANHost(host)
    default:
        return false
    }
}

private let lanSuffixes = [".local", ".lan", ".home.arpa", ".internal", ".ts.net"]

private func isLANHost(_ host: String) -> Bool {
    if host == "localhost" || host.hasSuffix(".localhost") { return true }
    if lanSuffixes.contains(where: { host.hasSuffix($0) }) { return true }
    if let octets = ipv4Octets(host) {
        return isLANIPv4(octets)
    }
    if host.contains(":") {
        return isLANIPv6(host)
    }
    return false
}

private func ipv4Octets(_ host: String) -> [Int]? {
    let parts = host.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4 else { return nil }
    var octets: [Int] = []
    for part in parts {
        guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber),
              let value = Int(part), value <= 255
        else { return nil }
        octets.append(value)
    }
    return octets
}

private func isLANIPv4(_ o: [Int]) -> Bool {
    switch (o[0], o[1]) {
    case (127, _): true // loopback
    case (10, _): true // RFC 1918
    case (172, 16...31): true // RFC 1918
    case (192, 168): true // RFC 1918
    case (169, 254): true // link-local
    case (100, 64...127): true // Tailscale / CGNAT
    default: false
    }
}

private func isLANIPv6(_ host: String) -> Bool {
    if host == "::1" { return true }
    // fe80::/10 link-local: first group fe80 through febf.
    let first = host.split(separator: ":", omittingEmptySubsequences: true).first.map(String.init) ?? ""
    guard first.count == 4, let group = UInt16(first, radix: 16) else { return false }
    return (group & 0xFFC0) == 0xFE80
}

/// A redirect is followed only when it stays on the same host (and does not
/// downgrade from https to http), so a token never follows a redirect elsewhere.
func isSafeRedirect(from original: URL?, to target: URL?) -> Bool {
    guard let original, let target,
          let originalHost = original.host?.lowercased(),
          let targetHost = target.host?.lowercased(),
          originalHost == targetHost
    else { return false }
    if original.scheme?.lowercased() == "https", target.scheme?.lowercased() != "https" { return false }
    return isAllowedBaseURL(target)
}

// MARK: - Transport

/// What `HedgerowHTTP` needs from the network. The real one wraps `URLSession`;
/// tests inject a stub.
protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest, maxBytes: Int) async throws -> (Data, HTTPURLResponse)
}

final class SameHostRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let origin: URL?

    init(origin: URL?) {
        self.origin = origin
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        // nil: do not follow; the 3xx response itself is returned to the caller.
        completionHandler(isSafeRedirect(from: origin, to: request.url) ? request : nil)
    }
}

struct URLSessionTransport: HTTPTransport {
    let session: URLSession

    func send(_ request: URLRequest, maxBytes: Int) async throws -> (Data, HTTPURLResponse) {
        let delegate = SameHostRedirectDelegate(origin: request.url)
        do {
            #if canImport(Darwin)
            // Stream so an oversized body is abandoned as soon as it passes the limit.
            let (bytes, response) = try await session.bytes(for: request, delegate: delegate)
            guard let http = response as? HTTPURLResponse else { throw HedgerowError.badResponse(0) }
            if http.expectedContentLength > Int64(maxBytes) { throw HedgerowError.tooLarge }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > maxBytes { throw HedgerowError.tooLarge }
            }
            return (data, http)
            #else
            let (data, response) = try await session.data(for: request, delegate: delegate)
            guard let http = response as? HTTPURLResponse else { throw HedgerowError.badResponse(0) }
            if data.count > maxBytes { throw HedgerowError.tooLarge }
            return (data, http)
            #endif
        } catch let error as HedgerowError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw HedgerowError.unreachable(error.localizedDescription)
        }
    }
}

// MARK: - Client

public struct HedgerowHTTP: Sendable {
    /// Responses larger than this are refused.
    public static let maxResponseBytes = 2 * 1024 * 1024

    private let token: String?
    private let transport: any HTTPTransport

    public init(token: String?, session: URLSession = .shared) {
        self.init(token: token, transport: URLSessionTransport(session: session))
    }

    init(token: String?, transport: any HTTPTransport) {
        self.token = token
        self.transport = transport
    }

    public func get<T: Decodable>(_ path: String, from base: URL) async throws -> T {
        let (data, status) = try await perform("GET", path, base: base, body: nil)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw HedgerowError.badResponse(status)
        }
    }

    /// Like `get`, but returns the raw body.
    public func getData(_ path: String, from base: URL) async throws -> Data {
        try await perform("GET", path, base: base, body: nil).data
    }

    public func post(_ path: String, to base: URL, body: Data?) async throws -> Data {
        try await perform("POST", path, base: base, body: body).data
    }

    private func perform(
        _ method: String, _ path: String, base: URL, body: Data?
    ) async throws -> (data: Data, status: Int) {
        // Checked before anything is sent, so a token never goes over plain http to a public host.
        guard isAllowedBaseURL(base), let url = Self.url(path, on: base) else {
            throw HedgerowError.insecureURL
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await transport.send(request, maxBytes: Self.maxResponseBytes)
        if data.count > Self.maxResponseBytes { throw HedgerowError.tooLarge }
        switch response.statusCode {
        case 200..<300: return (data, response.statusCode)
        case 401: throw HedgerowError.unauthorized
        case 403: throw HedgerowError.forbidden
        default: throw HedgerowError.badResponse(response.statusCode)
        }
    }

    /// `path` appended to the base (keeping any path prefix the service lives under).
    static func url(_ path: String, on base: URL) -> URL? {
        var root = base.absoluteString
        while root.hasSuffix("/") { root.removeLast() }
        let suffix = path.hasPrefix("/") ? path : "/" + path
        guard let url = URL(string: root + suffix),
              url.host?.lowercased() == base.host?.lowercased(),
              url.scheme?.lowercased() == base.scheme?.lowercased()
        else { return nil }
        return url
    }
}
