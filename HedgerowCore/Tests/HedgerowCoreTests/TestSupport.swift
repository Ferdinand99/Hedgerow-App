import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HedgerowCore

func fixture(_ name: String) throws -> Data {
    guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") else {
        throw FixtureError.missing(name)
    }
    return try Data(contentsOf: url)
}

enum FixtureError: Error {
    case missing(String)
}

/// Records what was sent and answers with whatever the handler returns.
final class StubTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private let handler: @Sendable (URLRequest) throws -> (Data, Int, [String: String])

    init(_ handler: @escaping @Sendable (URLRequest) throws -> (Data, Int)) {
        self.handler = { request in
            let (data, status) = try handler(request)
            return (data, status, [:])
        }
    }

    /// For tests that read response headers (`Retry-After`).
    init(withHeaders handler: @escaping @Sendable (URLRequest) throws -> (Data, Int, [String: String])) {
        self.handler = handler
    }

    /// Always answers with `status` and `body`.
    convenience init(status: Int, body: Data = Data()) {
        self.init { _ in (body, status) }
    }

    var requests: [URLRequest] {
        lock.withLock { recorded }
    }

    private func record(_ request: URLRequest) {
        lock.withLock { recorded.append(request) }
    }

    func send(_ request: URLRequest, maxBytes: Int) async throws -> (Data, HTTPURLResponse) {
        record(request)
        let (data, status, headers) = try handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        return (data, response)
    }
}
