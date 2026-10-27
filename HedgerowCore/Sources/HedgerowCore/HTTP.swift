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
    /// A 2xx answer whose content does not have the shape the app reads ("unexpected answer from the server").
    case unexpectedResponse
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
    if host.contains(":") {
        return isLANIPv6(host)
    }
    // Only a canonical dotted quad counts as an IP literal. Octal (010.0.0.1), hex (0x0a.0.0.1),
    // short (10.1) and single-integer (167772161) forms are read differently by the resolver
    // than by this check, so they are never treated as LAN addresses.
    if let octets = ipv4Octets(host) {
        return isLANIPv4(octets)
    }
    return false
}

/// Exactly four decimal octets, 0-255, no leading zeros.
private func ipv4Octets(_ host: String) -> [Int]? {
    let parts = host.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4 else { return nil }
    var octets: [Int] = []
    for part in parts {
        guard !part.isEmpty, part.count <= 3, part.allSatisfy({ $0.isASCII && $0.isNumber }),
              part == "0" || part.first != "0",
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

/// Loopback ::1, link-local fe80::/10, unique-local fc00::/7, and IPv4-mapped
/// addresses (::ffff:a.b.c.d) whose IPv4 address is itself LAN.
private func isLANIPv6(_ rawHost: String) -> Bool {
    var host = rawHost
    if let zone = host.firstIndex(of: "%") { host = String(host[..<zone]) }
    guard host.allSatisfy({ $0 == ":" || $0 == "." || $0.isHexDigit }) else { return false }
    if host == "::1" { return true }

    if host.hasPrefix("::ffff:") {
        let rest = String(host.dropFirst("::ffff:".count))
        if let octets = ipv4Octets(rest) { return isLANIPv4(octets) }
        let groups = rest.split(separator: ":", omittingEmptySubsequences: false)
        if groups.count == 2, groups.allSatisfy({ (1...4).contains($0.count) }),
           let high = UInt16(groups[0], radix: 16), let low = UInt16(groups[1], radix: 16) {
            return isLANIPv4([Int(high >> 8), Int(high & 0xFF), Int(low >> 8), Int(low & 0xFF)])
        }
        return false
    }

    // Any other address starting with "::" has leading zero groups, so it is not a LAN prefix.
    if host.hasPrefix(":") { return false }
    let first = host.split(separator: ":", omittingEmptySubsequences: false).first.map(String.init) ?? ""
    guard (1...4).contains(first.count), let group = UInt16(first, radix: 16) else { return false }
    return (group & 0xFFC0) == 0xFE80 || (group & 0xFE00) == 0xFC00
}

/// The port a URL really connects to (the scheme's default when none is written).
private func effectivePort(_ url: URL) -> Int? {
    if let port = url.port { return port }
    switch url.scheme?.lowercased() {
    case "https": return 443
    case "http": return 80
    default: return nil
    }
}

/// A redirect is followed only when it keeps the same scheme, host and port, so a
/// token never follows a redirect elsewhere (or from https down to http).
func isSafeRedirect(from original: URL?, to target: URL?) -> Bool {
    guard let original, let target,
          let originalHost = original.host?.lowercased(),
          let targetHost = target.host?.lowercased(),
          originalHost == targetHost,
          let originalScheme = original.scheme?.lowercased(),
          originalScheme == target.scheme?.lowercased(),
          let originalPort = effectivePort(original),
          originalPort == effectivePort(target)
    else { return false }
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

    /// Ephemeral: no URL cache, no cookie storage, no credential storage on disk.
    public static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration)
    }()

    public init(token: String?, session: URLSession = HedgerowHTTP.defaultSession) {
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
