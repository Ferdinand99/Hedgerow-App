import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HedgerowCore

private let eventJSON = Data(
    #"{"title":"🔴 Payments API is down","body":"Down since 10:02","kind":"problem","level":"critical","occurred_at":"2026-10-28T10:02:03Z"}"#.utf8
)

private struct Setup {
    let connection = Connection(name: "Work", baseURL: URL(string: "https://vole.example.com")!, kind: .vole)
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hedgerow-nse-\(UUID().uuidString)", isDirectory: true)
    let registry: PushRegistry
    let vault = InMemoryVault()
    let tag = "AbCdEfGhIjKlMnOpQrStUv"

    init(withToken: Bool = true, registered: Bool = true) throws {
        registry = PushRegistry(fileURL: directory.appendingPathComponent("push-tags.json"))
        if registered {
            try registry.save(PushEntry(
                tag: tag, connectionId: connection.id, relayDeviceId: "hrd_d", relayHandleId: "h-1", serverDeviceId: 5,
                created: Date()
            ))
        }
        if withToken { try vault.save("tok_SECRET", for: connection.id) }
    }

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }

    func rewriter(
        transport: some HTTPTransport, limit: Duration = .seconds(10), connections: [Connection]? = nil
    ) -> NotificationRewriter {
        let list = connections ?? [connection]
        return NotificationRewriter(registry: registry, connections: { list }, vault: vault, limit: limit) { connection, token in
            PushServerClient(baseURL: connection.baseURL, token: token, transport: transport)
        }
    }

    func payload(kind: String = "alert", ref: String? = "ref1") -> PushPayload {
        var hr: [String: Any] = ["v": 1, "k": kind, "t": tag]
        if let ref { hr["r"] = ref }
        return PushPayload.parse(["hr": hr])
    }
}

/// Never answers; only a cancellation ends it.
private struct HangingTransport: HTTPTransport {
    func send(_ request: URLRequest, maxBytes: Int) async throws -> (Data, HTTPURLResponse) {
        try await Task.sleep(for: .seconds(60))
        throw HedgerowError.unreachable("late")
    }
}

@Suite struct NotificationRewriterTests {
    @Test func theTextComesFromTheConnectionsOwnServerWithItsToken() async throws {
        let setup = try Setup()
        defer { setup.cleanUp() }
        let transport = StubTransport(status: 200, body: eventJSON)

        let result = await setup.rewriter(transport: transport).rewrite(setup.payload())

        #expect(result == NotificationRewrite(
            title: "🔴 Payments API is down", body: "Down since 10:02", threadIdentifier: setup.connection.id.uuidString
        ))
        let request = try #require(transport.requests.first)
        #expect(transport.requests.count == 1)
        #expect(request.url?.absoluteString == "https://vole.example.com/api/v1/push/events/ref1")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok_SECRET")
        // The request has its own limit as well.
        #expect(request.timeoutInterval == 10)
    }

    @Test func aSlowServerEndsAtTheLimitAndTheGenericTextStays() async throws {
        let setup = try Setup()
        defer { setup.cleanUp() }
        let started = ContinuousClock.now

        let result = await setup.rewriter(transport: HangingTransport(), limit: .milliseconds(200)).rewrite(setup.payload())

        #expect(result == NotificationRewrite(threadIdentifier: setup.connection.id.uuidString))
        #expect(result.title == nil && result.body == nil)
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func noTokenKeepsTheGenericTextAndAsksNothing() async throws {
        let setup = try Setup(withToken: false)
        defer { setup.cleanUp() }
        let transport = StubTransport(status: 200, body: eventJSON)

        let result = await setup.rewriter(transport: transport).rewrite(setup.payload())

        #expect(result == NotificationRewrite(threadIdentifier: setup.connection.id.uuidString))
        #expect(transport.requests.isEmpty)
    }

    @Test func aKeychainThatCannotBeReadIsTheSameAsNoToken() async throws {
        struct LockedVault: TokenVault {
            func save(_ token: String, for id: UUID) throws {}
            func token(for id: UUID) throws -> String? { throw HedgerowError.unauthorized }
            func delete(for id: UUID) throws {}
        }
        let setup = try Setup()
        defer { setup.cleanUp() }
        let transport = StubTransport(status: 200, body: eventJSON)
        let list = [setup.connection]
        let rewriter = NotificationRewriter(
            registry: setup.registry, connections: { list }, vault: LockedVault(), limit: .seconds(10)
        ) { connection, token in
            PushServerClient(baseURL: connection.baseURL, token: token, transport: transport)
        }

        let result = await rewriter.rewrite(setup.payload())

        #expect(result.title == nil)
        #expect(transport.requests.isEmpty)
    }

    @Test func anUnknownTagIsLeftAlone() async throws {
        let setup = try Setup(registered: false)
        defer { setup.cleanUp() }
        let transport = StubTransport(status: 200, body: eventJSON)

        let result = await setup.rewriter(transport: transport).rewrite(setup.payload())

        #expect(result == .unchanged)
        #expect(transport.requests.isEmpty)
    }

    @Test func aTagOfAConnectionThatIsGoneIsLeftAlone() async throws {
        let setup = try Setup()
        defer { setup.cleanUp() }
        let transport = StubTransport(status: 200, body: eventJSON)

        let result = await setup.rewriter(transport: transport, connections: []).rewrite(setup.payload())

        #expect(result == .unchanged)
        #expect(transport.requests.isEmpty)
    }

    @Test func anUnknownVersionIsLeftAlone() async throws {
        let setup = try Setup()
        defer { setup.cleanUp() }
        let transport = StubTransport(status: 200, body: eventJSON)
        let later = PushPayload.parse(["hr": ["v": 2, "k": "alert", "t": setup.tag, "r": "ref1"]])
        #expect(later == .unsupportedVersion)

        let result = await setup.rewriter(transport: transport).rewrite(later)

        #expect(result == .unchanged)
        #expect(transport.requests.isEmpty)
    }

    @Test func aMalformedPayloadIsLeftAlone() async throws {
        let setup = try Setup()
        defer { setup.cleanUp() }
        let transport = StubTransport(status: 200, body: eventJSON)
        #expect(await setup.rewriter(transport: transport).rewrite(.malformed) == .unchanged)
        #expect(transport.requests.isEmpty)
    }

    @Test func aSyncPushOrAnAlertWithoutARefChangesNoText() async throws {
        let setup = try Setup()
        defer { setup.cleanUp() }
        let transport = StubTransport(status: 200, body: eventJSON)

        #expect(await setup.rewriter(transport: transport).rewrite(setup.payload(kind: "sync", ref: nil)) == .unchanged)
        let noRef = await setup.rewriter(transport: transport).rewrite(setup.payload(ref: nil))
        #expect(noRef == NotificationRewrite(threadIdentifier: setup.connection.id.uuidString))
        #expect(transport.requests.isEmpty)
    }

    @Test func aServerThatFailsKeepsTheGenericTextButStillGroupsByConnection() async throws {
        let setup = try Setup()
        defer { setup.cleanUp() }
        for status in [404, 401, 500, 503] {
            let result = await setup.rewriter(transport: StubTransport(status: status)).rewrite(setup.payload())
            #expect(result == NotificationRewrite(threadIdentifier: setup.connection.id.uuidString), "status \(status)")
        }
        let offline = StubTransport { _ -> (Data, Int) in throw HedgerowError.unreachable("offline") }
        #expect(await setup.rewriter(transport: offline).rewrite(setup.payload()).title == nil)
    }

    @Test func anAnswerWithoutAUsableTitleKeepsTheGenericText() async throws {
        let setup = try Setup()
        defer { setup.cleanUp() }
        for body in [#"{"title":"","body":"b"}"#, #"{"title":"  \n ","body":"b"}"#, "<html>", "{}"] {
            let result = await setup.rewriter(transport: StubTransport(status: 200, body: Data(body.utf8))).rewrite(setup.payload())
            #expect(result.title == nil, "body \(body)")
        }
    }

    @Test func serverTextIsShownAsPlainText() async throws {
        let setup = try Setup()
        defer { setup.cleanUp() }
        let body = #"{"title":"A\u0000B‮CD\nE","body":"line1\r\nline2\u0007\t<b>x</b> [link](https://x.example)  "}"#

        let result = await setup.rewriter(transport: StubTransport(status: 200, body: Data(body.utf8))).rewrite(setup.payload())

        // Control and bidi characters are gone, a title is one line, markup stays as the text it is.
        #expect(result.title == "ABCD E")
        #expect(result.body == "line1\nline2 <b>x</b> [link](https://x.example)")
    }

    @Test func longTextIsCut() async throws {
        let setup = try Setup()
        defer { setup.cleanUp() }
        let body = #"{"title":"\#(String(repeating: "t", count: 500))","body":"\#(String(repeating: "b", count: 9000))"}"#

        let result = await setup.rewriter(transport: StubTransport(status: 200, body: Data(body.utf8))).rewrite(setup.payload())

        #expect(result.title?.count == 300)
        #expect(result.body?.count == 4000)
    }

    @Test func theRealInitializerUsesTheConnectionsAddress() async throws {
        // Without a stub: a tag nobody registered never reaches the network.
        let setup = try Setup(registered: false)
        defer { setup.cleanUp() }
        let rewriter = NotificationRewriter(registry: setup.registry, connections: { [setup.connection] }, vault: setup.vault)
        #expect(await rewriter.rewrite(setup.payload()) == .unchanged)
    }
}
