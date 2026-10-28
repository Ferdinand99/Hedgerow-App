import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HedgerowCore

private func defaults() -> UserDefaults {
    UserDefaults(suiteName: "hedgerow-tests-\(UUID().uuidString)")!
}

@Suite struct PushBackoffRecoveryTests {
    @Test func aNewRelayDeviceClearsWhatWasHeldBack() {
        let backoff = PushBackoff(defaults: defaults())
        let a = UUID(), b = UUID()
        let now = Date()
        backoff.noteRelayDevice("hrd_old")
        backoff.record(a, status: .tryLater, now: now)
        backoff.record(b, status: .serverPushOff, now: now)

        // The same device again: nothing changes.
        backoff.noteRelayDevice("hrd_old")
        #expect(backoff.blocked(a, now: now) == .tryLater)

        // Registered again: a new device id, a clean slate.
        backoff.noteRelayDevice("hrd_new")
        #expect(backoff.blocked(a, now: now) == nil)
        #expect(backoff.blocked(b, now: now) == nil)

        // A problem recorded for the new device is held back as before.
        backoff.record(a, status: .tryLater, now: now)
        backoff.noteRelayDevice("hrd_new")
        #expect(backoff.blocked(a, now: now) == .tryLater)
    }

    @Test func connectionsThatNoLongerExistArePurged() {
        let store = defaults()
        let backoff = PushBackoff(defaults: store)
        let preferences = PushPreferences(defaults: store)
        let kept = UUID(), gone = UUID()
        let now = Date()
        backoff.record(kept, status: .tryLater, now: now)
        backoff.record(gone, status: .failed, now: now)
        preferences.set(kept, on: false)
        preferences.set(gone, on: false)

        backoff.purge(keeping: [kept])
        preferences.purge(keeping: [kept])

        #expect(backoff.blocked(kept, now: now) == .tryLater)
        #expect(backoff.blocked(gone, now: now) == nil)
        #expect(!preferences.isOn(kept))
        // A purged "off" is the default again.
        #expect(preferences.isOn(gone))
    }

    @Test func purgingWithNothingToPurgeChangesNothing() {
        let backoff = PushBackoff(defaults: defaults())
        let id = UUID()
        backoff.record(id, status: .tryLater, now: Date())
        backoff.purge(keeping: [id])
        #expect(backoff.blocked(id) == .tryLater)
    }
}

@Suite struct PigeonReregisterTests {
    private let created = Data(#"{"device_id":"hrd_new1","manage_key":"hrm_new1"}"#.utf8)
    private let old = PigeonRecord(
        registration: PigeonRegistration(deviceId: "hrd_old1", manageKey: "hrm_old1"), token: "abab", lastSent: Date()
    )

    @Test func forgettingTheRegistrationMakesTheNextTokenRegisterANewDevice() async throws {
        let store = InMemoryPigeonStore(old)
        let transport = StubTransport(status: 201, body: created)
        let registrar = PigeonRegistrar(
            client: PigeonClient(baseURL: PigeonClient.relayURL, transport: transport), store: store, environment: .sandbox
        )

        await registrar.reregister()

        // Nothing is sent: the relay does not know the device, or refuses its key.
        #expect(transport.requests.isEmpty)
        #expect(await registrar.storedDeviceId() == nil)

        // Apple hands the token over again: a new device, not a keep-alive for the old one.
        let registration = try await registrar.apply(token: Data([0xAB, 0xAB]))
        #expect(registration.deviceId == "hrd_new1")
        #expect(transport.requests.map { $0.httpMethod } == ["POST"])
        #expect(await registrar.storedDeviceId() == "hrd_new1")
    }
}

@Suite struct NotificationGroupingTests {
    private let tag = "AbCdEfGhIjKlMnOpQrStUv"

    @Test func theGroupingNeedsNoNetworkAndNoToken() throws {
        let connection = Connection(name: "Work", baseURL: URL(string: "https://vole.example.com")!, kind: .vole)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hedgerow-group-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = PushRegistry(fileURL: directory.appendingPathComponent("push-tags.json"))
        try registry.save(PushEntry(
            tag: tag, connectionId: connection.id, relayDeviceId: "hrd_d", relayHandleId: "h-1", serverDeviceId: 5,
            created: Date()
        ))
        let rewriter = NotificationRewriter(registry: registry, connections: { [connection] }, vault: InMemoryVault())

        let alert = PushPayload.parse(["hr": ["v": 1, "k": "alert", "t": tag, "r": "abc"]])
        #expect(rewriter.grouping(for: alert) == NotificationRewrite(threadIdentifier: connection.id.uuidString))

        let unknownTag = PushPayload.parse(["hr": ["v": 1, "k": "alert", "t": "unknownunknownunknown00", "r": "abc"]])
        #expect(rewriter.grouping(for: unknownTag) == .unchanged)
        #expect(rewriter.grouping(for: .unsupportedVersion) == .unchanged)
        #expect(rewriter.grouping(for: .malformed) == .unchanged)
    }
}
