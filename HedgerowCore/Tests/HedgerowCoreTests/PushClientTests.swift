import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HedgerowCore

let sampleTag = "AbCdEfGhIjKlMnOpQrStUv"
let sampleHandleSecret = "hrh_" + String(repeating: "k", count: 43)
private let relay = PigeonClient.relayURL
private let registration = PigeonRegistration(deviceId: "hrd_device1", manageKey: "hrm_secret1")
private let handleReply = Data(#"{"handle_id":"h-1","handle":"\#(sampleHandleSecret)"}"#.utf8)

private func relayClient(_ transport: StubTransport) -> PigeonClient {
    PigeonClient(baseURL: relay, transport: transport)
}

// MARK: - Relay handles

@Suite struct PigeonHandleTests {
    @Test func createPostsTheTagWithTheManageKey() async throws {
        let transport = StubTransport(status: 201, body: handleReply)
        let handle = try await relayClient(transport).createHandle(registration, tag: sampleTag)

        #expect(handle == PigeonHandle(handleId: "h-1", handle: sampleHandleSecret))
        let request = try #require(transport.requests.first)
        #expect(transport.requests.count == 1)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://pigeon.hedgerow.tools/v1/devices/hrd_device1/handles")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer hrm_secret1")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try #require(request.httpBody)
        #expect(try JSONSerialization.jsonObject(with: body) as? [String: String] == ["tag": sampleTag])
    }

    @Test func aHandleDoesNotPrintItsSecret() {
        let handle = PigeonHandle(handleId: "h-1", handle: sampleHandleSecret)
        #expect(!"\(handle)".contains(sampleHandleSecret))
        #expect(!String(reflecting: handle).contains(sampleHandleSecret))
    }

    @Test func aMalformedTagIsNeverSent() async {
        let transport = StubTransport(status: 201, body: handleReply)
        for tag in ["", "short", "has/slash/in/the/tag12", String(repeating: "a", count: 40)] {
            await #expect(throws: PigeonError.unexpected) {
                _ = try await relayClient(transport).createHandle(registration, tag: tag)
            }
        }
        #expect(transport.requests.isEmpty)
    }

    @Test(arguments: [
        #"{"handle_id":"h-1","handle":"nope"}"#,
        #"{"handle_id":"../x","handle":"hrh_abc"}"#,
        #"{"handle":"hrh_abc"}"#,
        "<html>",
    ])
    func anAnswerThatIsNotAHandleIsUnexpected(body: String) async {
        let transport = StubTransport(status: 201, body: Data(body.utf8))
        await #expect(throws: PigeonError.unexpected) {
            _ = try await relayClient(transport).createHandle(registration, tag: sampleTag)
        }
    }

    @Test func createErrorsAreMapped() async {
        let table: [(Int, PigeonError)] = [
            (404, .gone), (401, .invalidCredentials), (409, .limitReached),
            (429, .rateLimited(retryAfter: nil)), (503, .unavailable), (400, .unexpected),
        ]
        for (status, expected) in table {
            let transport = StubTransport(status: status, body: Data(#"{"error":"x","message":"y"}"#.utf8))
            await #expect(throws: expected, "status \(status)") {
                _ = try await relayClient(transport).createHandle(registration, tag: sampleTag)
            }
        }
    }

    @Test func theHourlyLimitCarriesRetryAfter() async {
        let transport = StubTransport(withHeaders: { _ in (Data(), 429, ["Retry-After": "1800"]) })
        await #expect(throws: PigeonError.rateLimited(retryAfter: 1800)) {
            _ = try await relayClient(transport).createHandle(registration, tag: sampleTag)
        }
    }

    @Test func revokeDeletesTheHandle() async throws {
        let transport = StubTransport(status: 204)
        try await relayClient(transport).revokeHandle(registration, handleId: "h-1")
        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.absoluteString == "https://pigeon.hedgerow.tools/v1/devices/hrd_device1/handles/h-1")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer hrm_secret1")
    }

    @Test func aHandleThatIsAlreadyGoneCountsAsRevoked() async throws {
        let transport = StubTransport(status: 404, body: Data(#"{"error":"not_found","message":"no"}"#.utf8))
        try await relayClient(transport).revokeHandle(registration, handleId: "h-1")
    }

    @Test func revokeErrorsAreMapped() async {
        let table: [(Int, PigeonError)] = [(401, .invalidCredentials), (503, .unavailable), (500, .unexpected)]
        for (status, expected) in table {
            let transport = StubTransport(status: status)
            await #expect(throws: expected, "status \(status)") {
                try await relayClient(transport).revokeHandle(registration, handleId: "h-1")
            }
        }
    }

    @Test func aHandleIdThatCouldNotBePartOfAPathIsNeverSent() async {
        let transport = StubTransport(status: 204)
        for id in ["", "a/b", "../x", "a?b", "a b"] {
            await #expect(throws: PigeonError.unexpected) {
                try await relayClient(transport).revokeHandle(registration, handleId: id)
            }
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func listReadsTheHandlesWithoutTheirSecrets() async throws {
        let body = #"{"handles":[{"handle_id":"h-1","tag":"t1","created":"2026-10-27","last_used":null},{"handle_id":"h-2","tag":"t2","created":"2026-10-27","last_used":"2026-10-28"}]}"#
        let transport = StubTransport(status: 200, body: Data(body.utf8))
        let list = try await relayClient(transport).listHandles(registration)
        #expect(list == [PigeonHandleInfo(handleId: "h-1", tag: "t1"), PigeonHandleInfo(handleId: "h-2", tag: "t2")])
        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/v1/devices/hrd_device1/handles")
    }

    @Test func listOfAGoneDeviceIsGone() async {
        let transport = StubTransport(status: 404)
        await #expect(throws: PigeonError.gone) { _ = try await relayClient(transport).listHandles(registration) }
    }

    @Test func listOfSomethingElseIsUnexpected() async {
        let transport = StubTransport(status: 200, body: Data("[]".utf8))
        await #expect(throws: PigeonError.unexpected) { _ = try await relayClient(transport).listHandles(registration) }
    }
}

// MARK: - Server routes

private let server = URL(string: "https://vole.example.com")!
private let eventBody = Data(
    #"{"title":"🔴 Payments API is down","body":"Down since 10:02\nTarget: https://pay.example/health","kind":"problem","level":"critical","occurred_at":"2026-10-28T10:02:03Z"}"#.utf8
)

private func serverClient(_ transport: any HTTPTransport, base: URL = server, token: String = "tok_SECRET") -> PushServerClient {
    PushServerClient(baseURL: base, token: token, transport: transport)
}

private func envelope(_ code: String) -> Data {
    Data(#"{"error":{"code":"\#(code)","message":"m"}}"#.utf8)
}

@Suite struct PushServerRegisterTests {
    @Test func postsTheHandleWithTheConnectionsToken() async throws {
        let transport = StubTransport(status: 201, body: Data(#"{"id":42}"#.utf8))
        let device = try await serverClient(transport).register(handle: sampleHandleSecret)

        #expect(device == PushServerDevice(id: 42, isNew: true))
        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://vole.example.com/api/v1/push/devices")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok_SECRET")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try #require(request.httpBody)
        #expect(try JSONSerialization.jsonObject(with: body) as? [String: String] == ["handle": sampleHandleSecret])
    }

    @Test func theSameHandleAgainIs200WithTheSameId() async throws {
        let transport = StubTransport(status: 200, body: Data(#"{"id":42}"#.utf8))
        #expect(try await serverClient(transport).register(handle: sampleHandleSecret) == PushServerDevice(id: 42, isNew: false))
    }

    @Test func aPathPrefixOfTheServerIsKept() async throws {
        let transport = StubTransport(status: 201, body: Data(#"{"id":1}"#.utf8))
        _ = try await serverClient(transport, base: URL(string: "https://example.com/vole/")!).register(handle: sampleHandleSecret)
        #expect(transport.requests.first?.url?.absoluteString == "https://example.com/vole/api/v1/push/devices")
    }

    @Test func aLANServerOverHttpIsAllowed() async throws {
        let transport = StubTransport(status: 201, body: Data(#"{"id":1}"#.utf8))
        _ = try await serverClient(transport, base: URL(string: "http://10.0.3.26:3001")!).register(handle: sampleHandleSecret)
        #expect(transport.requests.count == 1)
    }

    @Test func aPublicServerOverHttpGetsNothing() async {
        let transport = StubTransport(status: 201, body: Data(#"{"id":1}"#.utf8))
        await #expect(throws: PushServerError.insecureURL) {
            _ = try await serverClient(transport, base: URL(string: "http://vole.example.com")!).register(handle: sampleHandleSecret)
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func aHandleThatIsNotWellFormedIsNeverSent() async {
        let transport = StubTransport(status: 201, body: Data(#"{"id":1}"#.utf8))
        for handle in ["", "hrh_", "nope_abc", "hrh_a/b", "hrh_" + String(repeating: "k", count: 200)] {
            await #expect(throws: PushServerError.unexpected) { _ = try await serverClient(transport).register(handle: handle) }
        }
        #expect(transport.requests.isEmpty)
    }

    @Test(arguments: [#"{"id":0}"#, #"{"id":"7"}"#, "{}", "<html>", #"{"id":-3}"#])
    func anAnswerWithoutAnIdIsUnexpected(body: String) async {
        let transport = StubTransport(status: 201, body: Data(body.utf8))
        await #expect(throws: PushServerError.unexpected) { _ = try await serverClient(transport).register(handle: sampleHandleSecret) }
    }

    @Test func serverErrorsAreMapped() async {
        let table: [(Int, Data, PushServerError)] = [
            (409, envelope("push_disabled"), .pushDisabled),
            (409, envelope("too_many_devices"), .tooManyDevices),
            (409, envelope("too_many_pending"), .tooManyPending),
            (409, envelope("something_else"), .unexpected),
            (409, Data(), .unexpected),
            (429, envelope("rate_limited"), .rateLimited(retryAfter: nil)),
            (401, envelope("unauthorized"), .unauthorized),
            (403, envelope("forbidden"), .forbidden),
            (404, envelope("not_found"), .notSupported),
            (405, Data(), .notSupported),
            (422, envelope("validation_failed"), .unexpected),
            (415, envelope("unsupported_media_type"), .unexpected),
            (500, Data(), .unexpected),
            (502, Data(), .unavailable),
            (503, Data(), .unavailable),
            (504, Data(), .unavailable),
            (302, Data(), .unexpected),
        ]
        for (status, body, expected) in table {
            let transport = StubTransport(status: status, body: body)
            await #expect(throws: expected, "status \(status)") {
                _ = try await serverClient(transport).register(handle: sampleHandleSecret)
            }
        }
    }

    @Test func theLimitCarriesRetryAfter() async {
        let transport = StubTransport(withHeaders: { _ in (Data(), 429, ["Retry-After": "120"]) })
        await #expect(throws: PushServerError.rateLimited(retryAfter: 120)) {
            _ = try await serverClient(transport).register(handle: sampleHandleSecret)
        }
    }

    @Test func noConnectionIsUnavailable() async {
        let transport = StubTransport { _ -> (Data, Int) in throw HedgerowError.unreachable("offline") }
        await #expect(throws: PushServerError.unavailable) { _ = try await serverClient(transport).register(handle: sampleHandleSecret) }
    }
}

@Suite struct PushServerUnregisterTests {
    @Test func deletesTheDevice() async throws {
        let transport = StubTransport(status: 204)
        try await serverClient(transport).unregister(deviceId: 42)
        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.absoluteString == "https://vole.example.com/api/v1/push/devices/42")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok_SECRET")
    }

    @Test func aDeviceThatIsAlreadyGoneCountsAsRemoved() async throws {
        try await serverClient(StubTransport(status: 404, body: envelope("not_found"))).unregister(deviceId: 42)
    }

    @Test func errorsAreMapped() async {
        let table: [(Int, PushServerError)] = [(401, .unauthorized), (403, .forbidden), (503, .unavailable), (500, .unexpected)]
        for (status, expected) in table {
            await #expect(throws: expected, "status \(status)") {
                try await serverClient(StubTransport(status: status)).unregister(deviceId: 42)
            }
        }
    }

    @Test func aDeviceIdThatIsNotPositiveIsNeverSent() async {
        let transport = StubTransport(status: 204)
        for id in [0, -1] {
            await #expect(throws: PushServerError.unexpected) { try await serverClient(transport).unregister(deviceId: id) }
        }
        #expect(transport.requests.isEmpty)
    }
}

@Suite struct PushServerEventTests {
    @Test func decodesTheText() async throws {
        let transport = StubTransport(status: 200, body: eventBody)
        let event = try await serverClient(transport).event(ref: "ref_AB-12")

        #expect(event.title == "🔴 Payments API is down")
        #expect(event.body == "Down since 10:02\nTarget: https://pay.example/health")
        #expect(event.kind == "problem")
        #expect(event.level == "critical")
        #expect(event.occurredAt == Date(timeIntervalSince1970: 1_793_181_723))
        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://vole.example.com/api/v1/push/events/ref_AB-12")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok_SECRET")
        // The request's own limit is the one asked for.
        let limited = StubTransport(status: 200, body: eventBody)
        _ = try await serverClient(limited).event(ref: "abc", timeout: 10)
        #expect(limited.requests.first?.timeoutInterval == 10)
    }

    @Test func aKindOrLevelThisVersionDoesNotKnowIsKept() async throws {
        let body = #"{"title":"t","body":"b","kind":"future_kind","level":"fatal","occurred_at":"2026-10-28T10:02:03.123Z","extra":1}"#
        let event = try await serverClient(StubTransport(status: 200, body: Data(body.utf8))).event(ref: "abc")
        #expect(event.kind == "future_kind")
        #expect(event.level == "fatal")
        #expect(event.occurredAt != nil)
    }

    @Test func onlyTitleAndBodyAreRequired() async throws {
        let event = try await serverClient(StubTransport(status: 200, body: Data(#"{"title":"t","body":""}"#.utf8))).event(ref: "abc")
        #expect(event == PushEvent(title: "t", body: ""))
    }

    @Test func aTimeThatCannotBeReadIsNoTime() async throws {
        let body = #"{"title":"t","body":"b","occurred_at":"yesterday"}"#
        let event = try await serverClient(StubTransport(status: 200, body: Data(body.utf8))).event(ref: "abc")
        #expect(event.occurredAt == nil)
    }

    @Test(arguments: [#"{"body":"b"}"#, #"{"title":"t"}"#, #"{"title":5,"body":"b"}"#, "[]", "<html>"])
    func anAnswerWithoutTheTextIsUnexpected(body: String) async {
        let transport = StubTransport(status: 200, body: Data(body.utf8))
        await #expect(throws: PushServerError.unexpected) { _ = try await serverClient(transport).event(ref: "abc") }
    }

    @Test func anExpiredOrUnknownRefIsNotFound() async {
        let transport = StubTransport(status: 404, body: envelope("not_found"))
        await #expect(throws: PushServerError.notFound) { _ = try await serverClient(transport).event(ref: "abc") }
    }

    @Test func otherStatusesAreMapped() async {
        let table: [(Int, PushServerError)] = [(401, .unauthorized), (403, .forbidden), (503, .unavailable), (500, .unexpected)]
        for (status, expected) in table {
            await #expect(throws: expected, "status \(status)") {
                _ = try await serverClient(StubTransport(status: status)).event(ref: "abc")
            }
        }
    }

    @Test func aRefThatCouldNotBeAKeyIsNeverSent() async {
        let transport = StubTransport(status: 200, body: eventBody)
        for ref in ["", "../x", "a/b", "https://evil.example/x", "a?b", String(repeating: "a", count: 65)] {
            await #expect(throws: PushServerError.unexpected) { _ = try await serverClient(transport).event(ref: ref) }
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func aBodyOverTheCapIsRefused() async {
        let big = Data(#"{"title":"t","body":""#.utf8) + Data(repeating: 0x61, count: 70 * 1024) + Data(#""}"#.utf8)
        let capped = CappingTransport(body: big)
        await #expect(throws: PushServerError.unexpected) { _ = try await serverClient(capped).event(ref: "abc") }
    }
}

/// Applies the cap the real transport applies.
private struct CappingTransport: HTTPTransport {
    let body: Data
    func send(_ request: URLRequest, maxBytes: Int) async throws -> (Data, HTTPURLResponse) {
        if body.count > maxBytes { throw HedgerowError.tooLarge }
        return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

// MARK: - Status mapping

@Suite struct PushStatusTests {
    @Test func serverErrorsBecomeCalmStates() {
        #expect(PushConnectionStatus(error: PushServerError.pushDisabled) == .serverPushOff)
        #expect(PushConnectionStatus(error: PushServerError.notSupported) == .serverNotReady)
        #expect(PushConnectionStatus(error: PushServerError.forbidden) == .serverNotReady)
        #expect(PushConnectionStatus(error: PushServerError.tooManyDevices) == .tryLater)
        #expect(PushConnectionStatus(error: PushServerError.tooManyPending) == .tryLater)
        #expect(PushConnectionStatus(error: PushServerError.rateLimited(retryAfter: 60)) == .tryLater)
        #expect(PushConnectionStatus(error: PushServerError.unavailable) == .tryLater)
        #expect(PushConnectionStatus(error: PushServerError.unauthorized) == .failed)
        #expect(PushConnectionStatus(error: PushServerError.unexpected) == .failed)
    }

    @Test func relayErrorsBecomeCalmStates() {
        #expect(PushConnectionStatus(error: PigeonError.rateLimited(retryAfter: nil)) == .tryLater)
        #expect(PushConnectionStatus(error: PigeonError.limitReached) == .tryLater)
        #expect(PushConnectionStatus(error: PigeonError.unavailable) == .tryLater)
        #expect(PushConnectionStatus(error: PigeonError.gone) == .tryLater)
        #expect(PushConnectionStatus(error: PigeonError.invalidCredentials) == .failed)
        #expect(PushConnectionStatus(error: PigeonError.unexpected) == .failed)
        #expect(PushConnectionStatus(error: CancellationError()) == .tryLater)
    }

    @Test func onlyProblemsAreWorthRemembering() {
        #expect(PushConnectionStatus.on.isProblem == false)
        #expect(PushConnectionStatus.off.isProblem == false)
        #expect(PushConnectionStatus.working.isProblem == false)
        #expect(PushConnectionStatus.serverPushOff.isProblem)
        #expect(PushConnectionStatus.tryLater.isProblem)
    }
}
