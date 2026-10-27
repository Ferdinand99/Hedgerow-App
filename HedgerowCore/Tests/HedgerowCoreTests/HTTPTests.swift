import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HedgerowCore

@Suite struct HTTPTests {
    private let base = URL(string: "https://vole.example.com")!

    @Test(arguments: [
        ("https://vole.example.com", true),
        ("http://10.0.3.26:3001", true),
        ("http://wren.ts.net", true),
        ("http://100.100.1.1", true),
        ("http://vole.example.com", false),
        ("http://100.128.0.1", false),
        // The rest of the LAN list.
        ("http://localhost:3001", true),
        ("http://127.0.0.1", true),
        ("http://172.16.0.5", true),
        ("http://172.31.255.1", true),
        ("http://172.32.0.1", false),
        ("http://192.168.1.10", true),
        ("http://169.254.10.10", true),
        ("http://100.64.0.1", true),
        ("http://100.63.255.255", false),
        ("http://nas.local", true),
        ("http://box.lan", true),
        ("http://router.home.arpa", true),
        ("http://wren.internal", true),
        ("http://[::1]:3001", true),
        ("http://[fe80::1]", true),
        ("http://[2001:db8::1]", false),
        // Look-alikes and unusable URLs.
        ("http://10.0.0.1.evil.com", false),
        ("http://evil-local.com", false),
        ("http://notts.net", false),
        ("http://user@10.0.0.1", false),
        ("ftp://10.0.0.1", false),
        ("https:///nohost", false),
    ])
    func allowsHttpsAndLanHttpOnly(urlString: String, expected: Bool) throws {
        let url = try #require(URL(string: urlString))
        #expect(isAllowedBaseURL(url) == expected, "\(urlString)")
    }

    @Test func mapsStatusCodes() async throws {
        for (status, expected) in [
            (401, HedgerowError.unauthorized),
            (403, .forbidden),
            (502, .badResponse(502)),
            (404, .badResponse(404)),
        ] {
            let http = HedgerowHTTP(token: "t", transport: StubTransport(status: status))
            await #expect(throws: expected) {
                try await http.getData("/api/v1/monitors", from: base)
            }
            await #expect(throws: expected) {
                try await http.post("/api/v1/monitors", to: base, body: nil)
            }
        }
    }

    @Test func sendsBearerTokenAndAppendsPathToBase() async throws {
        let stub = StubTransport(status: 200, body: Data("{\"n\":1}".utf8))
        let http = HedgerowHTTP(token: "vv_secret", transport: stub)
        struct Reply: Decodable { let n: Int }
        let reply: Reply = try await http.get("/api/v1/monitors?limit=5", from: URL(string: "https://example.com/vole/")!)
        #expect(reply.n == 1)
        let request = try #require(stub.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer vv_secret")
        #expect(request.url?.absoluteString == "https://example.com/vole/api/v1/monitors?limit=5")
        #expect(request.httpMethod == "GET")
    }

    @Test func postSendsBodyAsJSON() async throws {
        let stub = StubTransport(status: 200, body: Data("ok".utf8))
        let http = HedgerowHTTP(token: nil, transport: stub)
        let body = Data("{\"a\":1}".utf8)
        let reply = try await http.post("/api/v1/x", to: base, body: body)
        #expect(reply == Data("ok".utf8))
        let request = try #require(stub.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.httpBody == body)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func refusesInsecureURLBeforeSendingAnything() async throws {
        let stub = StubTransport(status: 200)
        let http = HedgerowHTTP(token: "vv_secret", transport: stub)
        let publicHTTP = try #require(URL(string: "http://vole.example.com"))
        await #expect(throws: HedgerowError.insecureURL) {
            try await http.getData("/api/v1/monitors", from: publicHTTP)
        }
        await #expect(throws: HedgerowError.insecureURL) {
            try await http.post("/api/v1/monitors", to: publicHTTP, body: nil)
        }
        #expect(stub.requests.isEmpty)
    }

    @Test func refusesBodiesOver2MiB() async throws {
        let limit = HedgerowHTTP.maxResponseBytes
        #expect(limit == 2 * 1024 * 1024)

        let tooBig = HedgerowHTTP(token: nil, transport: StubTransport(status: 200, body: Data(count: limit + 1)))
        await #expect(throws: HedgerowError.tooLarge) {
            try await tooBig.getData("/api/v1/x", from: base)
        }

        let exactly = HedgerowHTTP(token: nil, transport: StubTransport(status: 200, body: Data(count: limit)))
        let data = try await exactly.getData("/api/v1/x", from: base)
        #expect(data.count == limit)
    }

    @Test func undecodableBodyIsABadResponse() async throws {
        let http = HedgerowHTTP(token: nil, transport: StubTransport(status: 200, body: Data("<html>".utf8)))
        await #expect(throws: HedgerowError.badResponse(200)) {
            let _: [String: String] = try await http.get("/api/v1/x", from: base)
        }
    }

    @Test func redirectsStayOnTheSameHost() throws {
        let from = try #require(URL(string: "https://vole.example.com/api/v1/openapi.json"))
        func safe(_ to: String) -> Bool { isSafeRedirect(from: from, to: URL(string: to)) }
        #expect(safe("https://vole.example.com/other"))
        #expect(safe("https://VOLE.example.com/other"))
        #expect(!safe("https://login.example.com/sso"))
        #expect(!safe("https://vole.example.com.evil.net/"))
        #expect(!safe("http://vole.example.com/other"))
        #expect(!isSafeRedirect(from: from, to: nil))
    }
}
