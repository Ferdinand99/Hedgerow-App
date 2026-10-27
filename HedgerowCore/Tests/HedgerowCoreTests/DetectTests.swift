import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HedgerowCore

@Suite struct DetectTests {
    private let base = URL(string: "https://hedgerow.example.com")!

    private func detector(status: Int = 200, body: Data) -> (ServiceDetector, StubTransport) {
        let stub = StubTransport(status: status, body: body)
        return (ServiceDetector(http: HedgerowHTTP(token: "tok", transport: stub)), stub)
    }

    /// Like a real vole-kit server: the OpenAPI document needs a signed-in user, so it answers
    /// 401 unless the right Bearer token is sent, and 403 for a token without access.
    private func realServer(
        document: Data, accepted: String = "good", forbidden: Set<String> = []
    ) -> StubTransport {
        StubTransport { request in
            let header = request.value(forHTTPHeaderField: "Authorization") ?? ""
            guard header.hasPrefix("Bearer ") else { return (Data(#"{"error":"unauthorized"}"#.utf8), 401) }
            let sent = String(header.dropFirst("Bearer ".count))
            if forbidden.contains(sent) { return (Data(#"{"error":"forbidden"}"#.utf8), 403) }
            guard sent == accepted else { return (Data(#"{"error":"unauthorized"}"#.utf8), 401) }
            return (document, 200)
        }
    }

    private func detector(token: String?, against stub: StubTransport) -> ServiceDetector {
        ServiceDetector(http: HedgerowHTTP(token: token, transport: stub))
    }

    @Test(arguments: [
        ("openapi-vole.json", ServiceKind.vole),
        ("openapi-kestrel.json", .kestrel),
        ("openapi-wren.json", .wren),
    ])
    func detectsEachProduct(file: String, expected: ServiceKind) async throws {
        let (detector, stub) = detector(body: try fixture(file))
        #expect(try await detector.detect(base) == expected)
        let request = try #require(stub.requests.first)
        #expect(request.url?.path == "/api/v1/openapi.json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
    }

    @Test func validTokenDetectsOnAServerThatRequiresSignIn() async throws {
        let server = realServer(document: try fixture("openapi-vole.json"))
        #expect(try await detector(token: "good", against: server).detect(base) == .vole)
    }

    @Test(arguments: [nil, "wrong"] as [String?])
    func missingOrWrongTokenIsUnauthorized(token: String?) async throws {
        let server = realServer(document: try fixture("openapi-vole.json"))
        await #expect(throws: HedgerowError.unauthorized) {
            try await detector(token: token, against: server).detect(base)
        }
    }

    @Test func tokenWithoutAccessIsForbidden() async throws {
        let server = realServer(document: try fixture("openapi-vole.json"), forbidden: ["viewerless"])
        await #expect(throws: HedgerowError.forbidden) {
            try await detector(token: "viewerless", against: server).detect(base)
        }
    }

    @Test func htmlOkAnswerWithAValidTokenIsNotHedgerow() async throws {
        let server = realServer(document: try fixture("pangolin-login.html"))
        await #expect(throws: HedgerowError.notHedgerow) {
            try await detector(token: "good", against: server).detect(base)
        }
    }

    @Test func htmlLoginPageIsNotHedgerow() async throws {
        let (detector, _) = detector(body: try fixture("pangolin-login.html"))
        await #expect(throws: HedgerowError.notHedgerow) {
            try await detector.detect(base)
        }
    }

    @Test func foreignOpenAPIDocumentIsNotHedgerow() async throws {
        let body = Data(#"{"openapi":"3.0.0","info":{"title":"Petstore","version":"1"}}"#.utf8)
        let (detector, _) = detector(body: body)
        await #expect(throws: HedgerowError.notHedgerow) {
            try await detector.detect(base)
        }
    }

    @Test(arguments: [301, 302, 404])
    func redirectsAndNotFoundAreNotHedgerow(status: Int) async throws {
        let (detector, _) = detector(status: status, body: try fixture("pangolin-login.html"))
        await #expect(throws: HedgerowError.notHedgerow) {
            try await detector.detect(base)
        }
    }

    @Test(arguments: [(401, HedgerowError.unauthorized), (403, HedgerowError.forbidden)])
    func authStatusesAreAboutTheToken(status: Int, expected: HedgerowError) async throws {
        let (detector, _) = detector(status: status, body: try fixture("pangolin-login.html"))
        await #expect(throws: expected) {
            try await detector.detect(base)
        }
    }

    @Test func serverErrorStaysABadResponse() async throws {
        let (detector, _) = detector(status: 502, body: Data())
        await #expect(throws: HedgerowError.badResponse(502)) {
            try await detector.detect(base)
        }
    }

    @Test func insecureURLIsRefusedBeforeAnyRequest() async throws {
        let (detector, stub) = detector(body: try fixture("openapi-vole.json"))
        await #expect(throws: HedgerowError.insecureURL) {
            try await detector.detect(URL(string: "http://vole.example.com")!)
        }
        #expect(stub.requests.isEmpty)
    }

    @Test func titleMatchingIsRobust() {
        #expect(ServiceDetector.kind(forTitle: "Vigilant Vole API") == .vole)
        #expect(ServiceDetector.kind(forTitle: "Vigilant Vole") == .vole)
        #expect(ServiceDetector.kind(forTitle: "  keen kestrel api ") == .kestrel)
        #expect(ServiceDetector.kind(forTitle: "Wise Wren API") == .wren)
        #expect(ServiceDetector.kind(forTitle: "Vigilant Voles Inc") == nil)
        #expect(ServiceDetector.kind(forTitle: "Sign in") == nil)
        #expect(ServiceDetector.kind(forTitle: "") == nil)
    }
}
