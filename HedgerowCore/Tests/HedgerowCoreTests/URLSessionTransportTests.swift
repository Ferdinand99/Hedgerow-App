#if canImport(Darwin)
import Foundation
import Testing
@testable import HedgerowCore

/// A URLProtocol stub so the real URLSession transport (redirect delegate, streamed
/// size limit) runs without a network. Apple platforms only.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest, StubURLProtocol) -> Void

    nonisolated(unsafe) static var handler: Handler?
    nonisolated(unsafe) static var requestedHosts: [String] = []
    private static let lock = NSLock()

    static func reset(_ handler: @escaping Handler) {
        lock.lock()
        defer { lock.unlock() }
        self.handler = handler
        requestedHosts = []
    }

    static var hosts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return requestedHosts
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requestedHosts.append(request.url?.host ?? "")
        let handler = Self.handler
        Self.lock.unlock()
        handler?(request, self)
    }

    override func stopLoading() {}

    func respond(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    func redirect(to location: URL, status: Int = 302) {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Location": location.absoluteString]
        )!
        client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: location), redirectResponse: response)
    }
}

@Suite(.serialized) struct URLSessionTransportTests {
    private let base = URL(string: "https://vole.example.com")!

    private func http(token: String? = "vv_secret") -> HedgerowHTTP {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return HedgerowHTTP(token: token, session: URLSession(configuration: configuration))
    }

    @Test func refusesBodiesOver2MiB() async throws {
        StubURLProtocol.reset { _, proto in
            proto.respond(status: 200, body: Data(count: HedgerowHTTP.maxResponseBytes + 1))
        }
        await #expect(throws: HedgerowError.tooLarge) {
            try await http().getData("/api/v1/x", from: base)
        }
    }

    @Test func acceptsABodyExactlyAtTheLimit() async throws {
        StubURLProtocol.reset { _, proto in
            proto.respond(status: 200, body: Data(count: HedgerowHTTP.maxResponseBytes))
        }
        let data = try await http().getData("/api/v1/x", from: base)
        #expect(data.count == HedgerowHTTP.maxResponseBytes)
    }

    @Test func refusesCrossHostRedirect() async throws {
        let evil = URL(string: "https://evil.example.net/steal")!
        StubURLProtocol.reset { request, proto in
            if request.url?.host == "vole.example.com" {
                proto.redirect(to: evil)
            } else {
                proto.respond(status: 200, body: Data("{}".utf8))
            }
        }
        await #expect(throws: HedgerowError.badResponse(302)) {
            try await http().getData("/api/v1/x", from: base)
        }
        #expect(!StubURLProtocol.hosts.contains("evil.example.net"))
    }

    @Test func followsRedirectOnTheSameHost() async throws {
        StubURLProtocol.reset { request, proto in
            if request.url?.path == "/api/v1/x" {
                proto.redirect(to: URL(string: "https://vole.example.com/api/v1/y")!)
            } else {
                proto.respond(status: 200, body: Data("ok".utf8))
            }
        }
        let data = try await http().getData("/api/v1/x", from: base)
        #expect(data == Data("ok".utf8))
    }
}
#endif
