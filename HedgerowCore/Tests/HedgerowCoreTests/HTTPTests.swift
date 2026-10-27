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

    @Test(arguments: [
        // Range edges.
        ("http://172.15.255.255", false),
        ("http://172.16.0.0", true),
        ("http://172.31.255.255", true),
        ("http://172.32.0.0", false),
        ("http://100.63.255.255", false),
        ("http://100.64.0.0", true),
        ("http://100.127.255.255", true),
        ("http://100.128.0.0", false),
        ("http://192.167.1.1", false),
        ("http://169.253.1.1", false),
        ("http://11.0.0.1", false),
        // Case and trailing dots.
        ("http://NAS.LOCAL", true),
        ("http://Vole.Lan", true),
        ("http://WREN.TS.NET", true),
        ("http://LOCALHOST", true),
        ("http://vole.lan.", true),
        ("http://example.com.", false),
        ("https://example.com.", true),
        // IPv6: unique-local and link-local ranges.
        ("http://[fd00::1]", true),
        ("http://[fc00::1]", true),
        ("http://[fdab:cd12::5]:3001", true),
        ("http://[fe00::1]", false),
        ("http://[fe80::1]", true),
        ("http://[febf::1]", true),
        ("http://[fec0::1]", false),
        ("http://[FD00::1]", true),
        ("http://[2606:4700::1111]", false),
        ("http://[::2]", false),
        ("http://[::]", false),
        // IPv4-mapped IPv6 is LAN only when the mapped IPv4 is.
        ("http://[::ffff:10.0.0.1]", true),
        ("http://[::ffff:8.8.8.8]", false),
        ("http://[::ffff:a00:1]", true),
        ("http://[::ffff:808:808]", false),
        // Non-canonical IPv4 forms are read differently by the resolver (octal, hex, short, integer).
        ("http://010.0.0.1", false),
        ("http://172.016.0.1", false),
        ("http://10.0.0.01", false),
        ("http://192.168.01.1", false),
        ("http://0x0a.0.0.1", false),
        ("http://0x7f.0.0.1", false),
        ("http://0xa000001", false),
        ("http://10.1", false),
        ("http://127.1", false),
        ("http://10.0.1", false),
        ("http://167772161", false),
        ("http://2130706433", false),
        ("http://10.0.0.256", false),
        ("http://10.0.0.1.5", false),
        // https is still fine for any of these.
        ("https://010.0.0.1", true),
    ])
    func lanBoundariesAndNonCanonicalHosts(urlString: String, expected: Bool) {
        // A string that does not even parse as a URL is refused, which is what `false` expects.
        guard let url = URL(string: urlString) else {
            #expect(!expected, "\(urlString) did not parse")
            return
        }
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

    @Test func redirectsKeepSchemeAndPort() throws {
        func safe(_ from: String, _ to: String) -> Bool {
            isSafeRedirect(from: URL(string: from), to: URL(string: to))
        }
        // Same host, different port: refused.
        #expect(!safe("https://vole.example.com/a", "https://vole.example.com:8443/a"))
        #expect(!safe("https://vole.example.com:8443/a", "https://vole.example.com/a"))
        #expect(!safe("http://10.0.3.26:3001/a", "http://10.0.3.26:3002/a"))
        // An explicit default port is the same port.
        #expect(safe("https://vole.example.com/a", "https://vole.example.com:443/b"))
        #expect(safe("http://10.0.3.26:3001/a", "http://10.0.3.26:3001/b"))
        // Scheme changes are refused in both directions.
        #expect(!safe("https://vole.example.com/a", "http://vole.example.com/a"))
        #expect(!safe("http://10.0.3.26/a", "https://10.0.3.26/a"))
    }

    @Test func defaultSessionKeepsNothingOnDisk() {
        let configuration = HedgerowHTTP.defaultSession.configuration
        #expect(configuration.urlCache == nil)
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.httpShouldSetCookies == false)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
    }
}
