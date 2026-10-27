import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HedgerowCore

private let relay = PigeonClient.relayURL
private let token = Data(repeating: 0xAB, count: 32)
private let tokenHex = String(repeating: "ab", count: 32)
private let otherToken = Data(repeating: 0x01, count: 32)
private let otherTokenHex = String(repeating: "01", count: 32)
private let registration = PigeonRegistration(deviceId: "hrd_device1", manageKey: "hrm_secret1")
private let created = Data(#"{"device_id":"hrd_device1","manage_key":"hrm_secret1","extra":true}"#.utf8)

private func client(_ transport: StubTransport, base: URL = relay) -> PigeonClient {
    PigeonClient(baseURL: base, transport: transport)
}

private func json(_ request: URLRequest) throws -> [String: String] {
    let body = try #require(request.httpBody)
    return try #require(try JSONSerialization.jsonObject(with: body) as? [String: String])
}

@Suite struct PigeonRegisterTests {
    @Test func postsTheTokenAsLowercaseHex() async throws {
        let transport = StubTransport(status: 201, body: created)
        let result = try await client(transport).register(environment: .sandbox, token: token)

        #expect(result == registration)
        let request = try #require(transport.requests.first)
        #expect(transport.requests.count == 1)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://pigeon.hedgerow.tools/v1/devices")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        // Nothing to authenticate with yet: the manage key is what this call returns.
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(try json(request) == ["app": "hedgerow", "environment": "sandbox", "token": tokenHex])
        #expect(try #require(request.httpBody).count < 2048)
    }

    @Test func tokenIsLowercaseHexOfEveryByte() {
        #expect(Data([0x00, 0x0F, 0xA0, 0xFF]).hexString == "000fa0ff")
        #expect(Data().hexString == "")
    }

    @Test func aLargestAllowedTokenStaysUnderTwoKiB() async throws {
        let transport = StubTransport(status: 201, body: created)
        _ = try await client(transport).register(environment: .production, token: Data(repeating: 0xFE, count: 200))
        let request = try #require(transport.requests.first)
        #expect(try #require(request.httpBody).count < 2048)
        #expect(try json(request)["environment"] == "production")
    }

    @Test func aTokenThatCannotFitIsNeverSent() async {
        let transport = StubTransport(status: 201, body: created)
        await #expect(throws: PigeonError.unexpected) {
            _ = try await client(transport).register(environment: .production, token: Data(count: 2000))
        }
        #expect(transport.requests.isEmpty)
    }

    @Test(arguments: [
        #"{"device_id":"x","manage_key":"hrm_a"}"#,
        #"{"device_id":"hrd_a","manage_key":"nope"}"#,
        #"{"device_id":"hrd_a/../b","manage_key":"hrm_a"}"#,
        #"{"device_id":"hrd_a"}"#,
        "<html>",
    ])
    func anAnswerThatIsNotARegistrationIsUnexpected(body: String) async {
        let transport = StubTransport(status: 201, body: Data(body.utf8))
        await #expect(throws: PigeonError.unexpected) {
            _ = try await client(transport).register(environment: .sandbox, token: token)
        }
    }

    @Test func errorsAreMapped() async {
        let table: [(Int, PigeonError)] = [
            (400, .unexpected), (404, .unexpected), (409, .unexpected), (413, .unexpected),
            (429, .rateLimited(retryAfter: nil)), (503, .unavailable), (502, .unavailable), (500, .unexpected),
        ]
        for (status, expected) in table {
            let transport = StubTransport(status: status, body: Data(#"{"error":"x","message":"y"}"#.utf8))
            await #expect(throws: expected, "status \(status)") {
                _ = try await client(transport).register(environment: .sandbox, token: token)
            }
        }
    }
}

@Suite struct PigeonUpdateTests {
    @Test func putsWithTheManageKey() async throws {
        let transport = StubTransport(status: 204)
        try await client(transport).update(registration, token: otherToken, environment: .production)

        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.absoluteString == "https://pigeon.hedgerow.tools/v1/devices/hrd_device1")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer hrm_secret1")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(try json(request) == ["token": otherTokenHex, "environment": "production"])
        #expect(try #require(request.httpBody).count < 2048)
    }

    @Test func aKeepAliveWithoutNewValuesSendsAnEmptyObject() async throws {
        let transport = StubTransport(status: 204)
        try await client(transport).update(registration)
        let request = try #require(transport.requests.first)
        #expect(request.httpBody == Data("{}".utf8))
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test func aMissingRecordIsGone() async {
        let transport = StubTransport(status: 404, body: Data(#"{"error":"not_found","message":"no"}"#.utf8))
        await #expect(throws: PigeonError.gone) { try await client(transport).update(registration) }
    }

    @Test func errorsAreMapped() async {
        let table: [(Int, PigeonError)] = [
            (401, .invalidCredentials), (503, .unavailable), (400, .unexpected), (413, .unexpected),
        ]
        for (status, expected) in table {
            let transport = StubTransport(status: status)
            await #expect(throws: expected, "status \(status)") { try await client(transport).update(registration) }
        }
    }

    @Test func rateLimitCarriesRetryAfter() async {
        let withHeader = StubTransport(withHeaders: { _ in (Data(), 429, ["Retry-After": "60"]) })
        await #expect(throws: PigeonError.rateLimited(retryAfter: 60)) { try await client(withHeader).update(registration) }

        let without = StubTransport(status: 429)
        await #expect(throws: PigeonError.rateLimited(retryAfter: nil)) { try await client(without).update(registration) }

        // Not a number of seconds: no guess.
        let date = StubTransport(withHeaders: { _ in (Data(), 429, ["Retry-After": "Wed, 21 Oct 2026 07:28:00 GMT"]) })
        await #expect(throws: PigeonError.rateLimited(retryAfter: nil)) { try await client(date).update(registration) }
    }

    @Test func serviceUnavailableIsUnavailable() async {
        let transport = StubTransport(withHeaders: { _ in (Data(), 503, ["Retry-After": "30"]) })
        await #expect(throws: PigeonError.unavailable) { try await client(transport).update(registration) }
    }

    @Test func offlineIsUnavailable() async {
        let transport = StubTransport(withHeaders: { _ in throw HedgerowError.unreachable("offline") })
        await #expect(throws: PigeonError.unavailable) { try await client(transport).update(registration) }
    }

    @Test func idsThatCouldChangeThePathAreNeverSent() async {
        let transport = StubTransport(status: 204)
        for bad in [
            PigeonRegistration(deviceId: "hrd_../v1/instances/self", manageKey: "hrm_a"),
            PigeonRegistration(deviceId: "hrd_a?x=1", manageKey: "hrm_a"),
            PigeonRegistration(deviceId: "hrd_a", manageKey: "hrm_a\r\nX-Evil: 1"),
            PigeonRegistration(deviceId: "", manageKey: ""),
            PigeonRegistration(deviceId: "device", manageKey: "hrm_a"),
        ] {
            await #expect(throws: PigeonError.unexpected) { try await client(transport).update(bad) }
            await #expect(throws: PigeonError.unexpected) { try await client(transport).remove(bad) }
        }
        #expect(transport.requests.isEmpty)
    }
}

@Suite struct PigeonRemoveTests {
    @Test func deletesWithTheManageKey() async throws {
        let transport = StubTransport(status: 204)
        try await client(transport).remove(registration)
        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.absoluteString == "https://pigeon.hedgerow.tools/v1/devices/hrd_device1")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer hrm_secret1")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test func aRecordThatIsAlreadyGoneCountsAsRemoved() async throws {
        try await client(StubTransport(status: 404)).remove(registration)
    }

    @Test func errorsAreMapped() async {
        let table: [(Int, PigeonError)] = [(401, .invalidCredentials), (503, .unavailable), (500, .unexpected)]
        for (status, expected) in table {
            await #expect(throws: expected, "status \(status)") {
                try await client(StubTransport(status: status)).remove(registration)
            }
        }
        let limited = StubTransport(withHeaders: { _ in (Data(), 429, ["Retry-After": "60"]) })
        await #expect(throws: PigeonError.rateLimited(retryAfter: 60)) { try await client(limited).remove(registration) }
    }
}

@Suite struct PigeonSafetyTests {
    @Test func theRelayIsAnHttpsAddress() {
        #expect(PigeonClient.relayURL.absoluteString == "https://pigeon.hedgerow.tools")
    }

    @Test(arguments: ["http://pigeon.hedgerow.tools", "http://10.0.3.26:8080", "http://localhost:8080"])
    func plainHttpIsRefusedEvenToTheLAN(address: String) async throws {
        let transport = StubTransport(status: 201, body: created)
        let http = client(transport, base: try #require(URL(string: address)))
        await #expect(throws: PigeonError.insecureURL) { _ = try await http.register(environment: .sandbox, token: token) }
        await #expect(throws: PigeonError.insecureURL) { try await http.update(registration) }
        await #expect(throws: PigeonError.insecureURL) { try await http.remove(registration) }
        #expect(transport.requests.isEmpty)
    }

    @Test func aRedirectThatWasRefusedIsUnexpected() async {
        // The URLSession transport only follows a redirect to the same scheme, host and port
        // (isSafeRedirect, tested in HTTPTests); anything else comes back as the 3xx itself.
        for status in [301, 302, 307, 308] {
            let transport = StubTransport(withHeaders: { _ in (Data(), status, ["Location": "https://evil.example/v1/devices"]) })
            await #expect(throws: PigeonError.unexpected, "status \(status)") {
                _ = try await client(transport).register(environment: .sandbox, token: token)
            }
            await #expect(throws: PigeonError.unexpected, "status \(status)") {
                try await client(transport).update(registration)
            }
            await #expect(throws: PigeonError.unexpected, "status \(status)") {
                try await client(transport).remove(registration)
            }
        }
    }

    @Test func responsesAreCappedAt64KiB() async {
        #expect(PigeonClient.maxResponseBytes == 64 * 1024)
        let big = StubTransport(status: 201, body: Data(count: PigeonClient.maxResponseBytes + 1))
        await #expect(throws: PigeonError.unexpected) {
            _ = try await client(big).register(environment: .sandbox, token: token)
        }
    }

    @Test func theTransportIsToldTheSmallLimit() async throws {
        final class Limit: HTTPTransport, @unchecked Sendable {
            private let lock = NSLock()
            private var seen: [Int] = []
            var limits: [Int] { lock.withLock { seen } }
            func send(_ request: URLRequest, maxBytes: Int) async throws -> (Data, HTTPURLResponse) {
                lock.withLock { seen.append(maxBytes) }
                return (Data(), HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
            }
        }
        let transport = Limit()
        try await PigeonClient(baseURL: relay, transport: transport).update(registration)
        #expect(transport.limits == [64 * 1024])
    }
}

@Suite struct PigeonKeepAliveTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func neverSentIsDue() {
        #expect(needsKeepAlive(lastSent: nil, now: now))
    }

    @Test func dueOnceADayHasPassed() {
        let day: TimeInterval = 24 * 3600
        #expect(!needsKeepAlive(lastSent: now, now: now))
        #expect(!needsKeepAlive(lastSent: now.addingTimeInterval(-day + 1), now: now))
        #expect(needsKeepAlive(lastSent: now.addingTimeInterval(-day), now: now))
        #expect(needsKeepAlive(lastSent: now.addingTimeInterval(-day - 1), now: now))
        #expect(needsKeepAlive(lastSent: now.addingTimeInterval(-90 * day), now: now))
    }

    @Test func aTimeInTheFutureIsDue() {
        #expect(needsKeepAlive(lastSent: now.addingTimeInterval(1), now: now))
    }
}

// MARK: - Registrar

/// A relay that remembers nothing, answering by method with a status that can be changed.
private final class FakeRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var statuses: [String: Int] = ["POST": 201, "PUT": 204, "DELETE": 204]
    private var offline = false
    private var issued = 0

    func set(_ method: String, _ status: Int) { lock.withLock { statuses[method] = status } }
    func setOffline(_ value: Bool) { lock.withLock { offline = value } }

    func transport() -> StubTransport {
        StubTransport { [self] request in
            let (status, isOffline, number): (Int, Bool, Int) = lock.withLock {
                if request.httpMethod == "POST" { issued += 1 }
                return (statuses[request.httpMethod ?? ""] ?? 500, offline, issued)
            }
            if isOffline { throw HedgerowError.unreachable("offline") }
            if request.httpMethod == "POST", status == 201 {
                return (Data(#"{"device_id":"hrd_new\#(number)","manage_key":"hrm_new\#(number)"}"#.utf8), 201)
            }
            return (Data(), status)
        }
    }
}

private extension StubTransport {
    var methods: [String] { requests.map { $0.httpMethod ?? "" } }
}

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let hour: TimeInterval = 3600

private func registrar(
    _ transport: StubTransport, store: InMemoryPigeonStore, at date: Date = t0,
    environment: PigeonEnvironment = .sandbox
) -> PigeonRegistrar {
    PigeonRegistrar(client: client(transport), store: store, environment: environment, now: { date })
}

@Suite struct PigeonRegistrarTests {
    @Test func firstTokenRegistersAndStoresEverything() async throws {
        let fake = FakeRelay()
        let transport = fake.transport()
        let store = InMemoryPigeonStore()

        let result = try await registrar(transport, store: store).apply(token: token)

        #expect(result == PigeonRegistration(deviceId: "hrd_new1", manageKey: "hrm_new1"))
        #expect(transport.methods == ["POST"])
        #expect(try store.load() == PigeonRecord(registration: result, token: tokenHex, lastSent: t0))
    }

    @Test func theSameTokenWithinADayTouchesNothing() async throws {
        let fake = FakeRelay()
        let transport = fake.transport()
        let store = InMemoryPigeonStore()
        try await registrar(transport, store: store).apply(token: token)
        try await registrar(transport, store: store, at: t0.addingTimeInterval(23 * hour)).apply(token: token)
        #expect(transport.methods == ["POST"])
    }

    @Test func aDueKeepAliveIsOnePutAndMovesTheDate() async throws {
        let fake = FakeRelay()
        let transport = fake.transport()
        let store = InMemoryPigeonStore()
        let first = try await registrar(transport, store: store).apply(token: token)

        let later = t0.addingTimeInterval(25 * hour)
        let again = try await registrar(transport, store: store, at: later).apply(token: token)

        #expect(again == first)
        #expect(transport.methods == ["POST", "PUT"])
        #expect(try store.load()?.lastSent == later)
        #expect(try store.load()?.registration == first)
        // Right after, nothing more is sent.
        try await registrar(transport, store: store, at: later.addingTimeInterval(60)).apply(token: token)
        #expect(transport.methods == ["POST", "PUT"])
    }

    @Test func aNewTokenIsPutRightAway() async throws {
        let fake = FakeRelay()
        let transport = fake.transport()
        let store = InMemoryPigeonStore()
        let first = try await registrar(transport, store: store).apply(token: token)

        let soon = t0.addingTimeInterval(60)
        let result = try await registrar(transport, store: store, at: soon, environment: .production).apply(token: otherToken)

        #expect(result == first)
        #expect(transport.methods == ["POST", "PUT"])
        let put = try #require(transport.requests.last)
        #expect(try json(put) == ["token": otherTokenHex, "environment": "production"])
        #expect(try store.load() == PigeonRecord(registration: first, token: otherTokenHex, lastSent: soon))
    }

    @Test func aRecordThatIsGoneIsRegisteredAgainAndTheIdsReplaced() async throws {
        let fake = FakeRelay()
        let transport = fake.transport()
        let store = InMemoryPigeonStore()
        let first = try await registrar(transport, store: store).apply(token: token)

        fake.set("PUT", 404)
        let later = t0.addingTimeInterval(25 * hour)
        let second = try await registrar(transport, store: store, at: later).apply(token: token)

        #expect(second == PigeonRegistration(deviceId: "hrd_new2", manageKey: "hrm_new2"))
        #expect(second != first)
        #expect(transport.methods == ["POST", "PUT", "POST"])
        #expect(try store.load() == PigeonRecord(registration: second, token: tokenHex, lastSent: later))
    }

    @Test func aRefusedManageKeyIsRegisteredAgainToo() async throws {
        let fake = FakeRelay()
        let transport = fake.transport()
        let store = InMemoryPigeonStore()
        try await registrar(transport, store: store).apply(token: token)
        fake.set("PUT", 401)
        let second = try await registrar(transport, store: store, at: t0.addingTimeInterval(25 * hour)).apply(token: token)
        #expect(second.deviceId == "hrd_new2")
        #expect(transport.methods == ["POST", "PUT", "POST"])
    }

    @Test func aGoneRecordThatCannotBeRegisteredAgainKeepsTheOldRecordAndFails() async throws {
        let fake = FakeRelay()
        let transport = fake.transport()
        let store = InMemoryPigeonStore()
        let first = try await registrar(transport, store: store).apply(token: token)
        let before = try store.load()

        fake.set("PUT", 404)
        fake.set("POST", 429)
        await #expect(throws: PigeonError.rateLimited(retryAfter: nil)) {
            try await registrar(transport, store: store, at: t0.addingTimeInterval(25 * hour)).apply(token: token)
        }
        // The next launch tries the same again; nothing was lost.
        #expect(try store.load() == before)
        #expect(try store.load()?.registration == first)
    }

    @Test(arguments: [(503, PigeonError.unavailable), (429, PigeonError.rateLimited(retryAfter: nil))])
    func relayTroubleOnFirstRegistrationStoresNothing(status: Int, expected: PigeonError) async {
        let fake = FakeRelay()
        fake.set("POST", status)
        let store = InMemoryPigeonStore()
        await #expect(throws: expected) { try await registrar(fake.transport(), store: store).apply(token: token) }
        #expect((try? store.load()) == nil)
    }

    @Test func offlineKeepAliveFailsCalmlyAndKeepsTheRecord() async throws {
        let fake = FakeRelay()
        let transport = fake.transport()
        let store = InMemoryPigeonStore()
        try await registrar(transport, store: store).apply(token: token)
        let before = try store.load()

        fake.setOffline(true)
        await #expect(throws: PigeonError.unavailable) {
            try await registrar(transport, store: store, at: t0.addingTimeInterval(25 * hour)).apply(token: token)
        }
        #expect(try store.load() == before)
    }

    @Test func aRegistrationThatCannotBeStoredIsRemovedAgain() async throws {
        struct BrokenStore: PigeonStore {
            struct Failure: Error {}
            func load() throws -> PigeonRecord? { nil }
            func save(_ record: PigeonRecord) throws { throw Failure() }
            func clear() throws {}
        }
        let fake = FakeRelay()
        let transport = fake.transport()
        let registrar = PigeonRegistrar(client: client(transport), store: BrokenStore(), environment: .sandbox, now: { t0 })
        await #expect(throws: BrokenStore.Failure.self) { try await registrar.apply(token: token) }
        #expect(transport.methods == ["POST", "DELETE"])
        #expect(transport.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer hrm_new1")
    }

    @Test func disablingDeletesAtTheRelayThenClearsTheStore() async throws {
        let fake = FakeRelay()
        let transport = fake.transport()
        let store = InMemoryPigeonStore()
        try await registrar(transport, store: store).apply(token: token)

        let confirmed = await registrar(transport, store: store).disable()

        #expect(confirmed)
        #expect(transport.methods == ["POST", "DELETE"])
        #expect(transport.requests.last?.url?.path == "/v1/devices/hrd_new1")
        #expect(try store.load() == nil)
    }

    @Test(arguments: [503, 429, 401, 500])
    func disablingClearsTheStoreEvenWhenTheRelayRefuses(status: Int) async throws {
        let fake = FakeRelay()
        let transport = fake.transport()
        let store = InMemoryPigeonStore()
        try await registrar(transport, store: store).apply(token: token)

        fake.set("DELETE", status)
        let confirmed = await registrar(transport, store: store).disable()
        #expect(!confirmed)
        #expect(try store.load() == nil)
    }

    @Test func disablingOfflineClearsTheStore() async throws {
        let fake = FakeRelay()
        let transport = fake.transport()
        let store = InMemoryPigeonStore()
        try await registrar(transport, store: store).apply(token: token)

        fake.setOffline(true)
        let confirmed = await registrar(transport, store: store).disable()
        #expect(!confirmed)
        #expect(try store.load() == nil)
        #expect(await registrar(transport, store: store).storedDeviceId() == nil)
    }

    @Test func disablingWithNothingStoredSendsNothing() async {
        let transport = FakeRelay().transport()
        let confirmed = await registrar(transport, store: InMemoryPigeonStore()).disable()
        #expect(confirmed)
        #expect(transport.requests.isEmpty)
    }

    @Test func enablingAgainAfterDisablingRegistersAFreshDevice() async throws {
        let fake = FakeRelay()
        let transport = fake.transport()
        let store = InMemoryPigeonStore()
        try await registrar(transport, store: store).apply(token: token)
        await registrar(transport, store: store).disable()
        let again = try await registrar(transport, store: store).apply(token: token)
        #expect(again.deviceId == "hrd_new2")
        #expect(transport.methods == ["POST", "DELETE", "POST"])
    }

    @Test func storedDeviceIdIsTheNotSecretPart() async throws {
        let fake = FakeRelay()
        let store = InMemoryPigeonStore()
        let subject = registrar(fake.transport(), store: store)
        #expect(await subject.storedDeviceId() == nil)
        try await subject.apply(token: token)
        #expect(await subject.storedDeviceId() == "hrd_new1")
    }
}

@Test func printingARegistrationOrRecordHidesTheSecrets() {
    let registration = PigeonRegistration(deviceId: "hrd_abc", manageKey: "hrm_secret")
    let record = PigeonRecord(registration: registration, token: "a1b2c3", lastSent: Date(timeIntervalSince1970: 0))
    for text in ["\(registration)", String(reflecting: registration), "\(record)", String(reflecting: record)] {
        #expect(text.contains("hrd_abc"))
        #expect(!text.contains("hrm_secret"))
        #expect(!text.contains("a1b2c3"))
    }
}
