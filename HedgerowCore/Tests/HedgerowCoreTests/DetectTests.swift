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
        return (ServiceDetector(http: HedgerowHTTP(token: nil, transport: stub)), stub)
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
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
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

    @Test(arguments: [301, 302, 401, 403, 404])
    func gatewayAnswersAreNotHedgerow(status: Int) async throws {
        let (detector, _) = detector(status: status, body: try fixture("pangolin-login.html"))
        await #expect(throws: HedgerowError.notHedgerow) {
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
