import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HedgerowCore

// MARK: - Fakes

/// What happened, in order, across the relay and the servers.
final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func add(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
    func count(_ prefix: String) -> Int { all.filter { $0.hasPrefix(prefix) }.count }
    func clear() { lock.withLock { lines.removeAll() } }
}

/// Postal Pigeon, as far as handles go.
final class PushFakeRelay: @unchecked Sendable {
    private let lock = NSLock()
    private let log: CallLog
    private var counter = 0
    /// handle id -> the handle secret.
    private var live: [String: String] = [:]
    var createStatus = 201
    var revokeStatus = 204
    var listStatus = 200
    private(set) var transport: StubTransport!

    init(log: CallLog) {
        self.log = log
        transport = StubTransport { [unowned self] request in try self.answer(request) }
    }

    var handleIds: Set<String> { lock.withLock { Set(live.keys) } }
    func secret(of handleId: String) -> String? { lock.withLock { live[handleId] } }

    /// A handle the relay has that the app never wrote down.
    func addUnknown(_ id: String) { lock.withLock { live[id] = "hrh_" + String(repeating: "u", count: 40) } }
    func forget(_ id: String) { lock.withLock { _ = live.removeValue(forKey: id) } }

    private func answer(_ request: URLRequest) throws -> (Data, Int) {
        let path = request.url?.path ?? ""
        switch (request.httpMethod ?? "", path.split(separator: "/").count) {
        case ("POST", 4):
            log.add("relay.create")
            if createStatus != 201 { return (Data(#"{"error":"x","message":"y"}"#.utf8), createStatus) }
            return lock.withLock {
                counter += 1
                let id = "h-\(counter)"
                let secret = "hrh_" + String(repeating: Character(String(counter % 10)), count: 43)
                live[id] = secret
                return (Data(#"{"handle_id":"\#(id)","handle":"\#(secret)"}"#.utf8), 201)
            }
        case ("DELETE", 5):
            let id = String(path.split(separator: "/").last ?? "")
            log.add("relay.revoke \(id)")
            if revokeStatus >= 400 && revokeStatus != 404 { return (Data(), revokeStatus) }
            lock.withLock { _ = live.removeValue(forKey: id) }
            return (Data(), revokeStatus)
        case ("GET", 4):
            log.add("relay.list")
            if listStatus != 200 { return (Data(), listStatus) }
            let items = lock.withLock { live.keys.sorted() }.map { #"{"handle_id":"\#($0)","tag":"t","created":"2026-10-28","last_used":null}"# }
            return (Data(#"{"handles":[\#(items.joined(separator: ","))]}"#.utf8), 200)
        default:
            return (Data(), 400)
        }
    }
}

/// One Hedgerow server's push routes.
final class PushFakeServer: @unchecked Sendable {
    private let lock = NSLock()
    private let log: CallLog
    private let name: String
    private var counter = 100
    /// device id -> the handle given.
    private var devices: [Int: String] = [:]
    var registerStatus: Int?
    var registerCode = "push_disabled"
    var deleteStatus = 204
    private(set) var transport: StubTransport!

    init(name: String, log: CallLog) {
        self.name = name
        self.log = log
        transport = StubTransport { [unowned self] request in try self.answer(request) }
    }

    var deviceIds: Set<Int> { lock.withLock { Set(devices.keys) } }
    func handle(of id: Int) -> String? { lock.withLock { devices[id] } }

    private func answer(_ request: URLRequest) throws -> (Data, Int) {
        let path = request.url?.path ?? ""
        switch request.httpMethod ?? "" {
        case "POST":
            log.add("\(name).register")
            if let status = registerStatus {
                return (Data(#"{"error":{"code":"\#(registerCode)","message":"m"}}"#.utf8), status)
            }
            let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: String]
            let handle = body?["handle"] ?? ""
            return lock.withLock {
                if let existing = devices.first(where: { $0.value == handle }) {
                    return (Data(#"{"id":\#(existing.key)}"#.utf8), 200)
                }
                counter += 1
                devices[counter] = handle
                return (Data(#"{"id":\#(counter)}"#.utf8), 201)
            }
        case "DELETE":
            let id = Int(path.split(separator: "/").last ?? "") ?? 0
            log.add("\(name).unregister \(id)")
            if deleteStatus >= 400 && deleteStatus != 404 { return (Data(), deleteStatus) }
            lock.withLock { _ = devices.removeValue(forKey: id) }
            return (Data(), deleteStatus)
        default:
            return (Data(), 400)
        }
    }
}

final class TagCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> String {
        let n = lock.withLock { value += 1; return value }
        let text = "tag\(n)"
        return text + String(repeating: "x", count: 22 - text.count)
    }
}

/// An app with a Postal Pigeon registration, a relay and a server per connection.
struct PushWorld {
    static let relayDevice = PigeonRegistration(deviceId: "hrd_device1", manageKey: "hrm_secret1")

    let log = CallLog()
    let relay: PushFakeRelay
    let servers: [UUID: PushFakeServer]
    let connections: [Connection]
    let registry: PushRegistry
    let pigeonStore: InMemoryPigeonStore
    let manager: PushHandleManager
    let directory: URL

    init(connectionCount: Int = 1, registered: Bool = true, registryFile: URL? = nil) {
        let log = log
        let relay = PushFakeRelay(log: log)
        self.relay = relay
        var connections: [Connection] = []
        var servers: [UUID: PushFakeServer] = [:]
        for index in 0..<connectionCount {
            let kind = ServiceKind.allCases[index % ServiceKind.allCases.count]
            let connection = Connection(
                name: "Server \(index)", baseURL: URL(string: "https://s\(index).example.com")!, kind: kind
            )
            connections.append(connection)
            servers[connection.id] = PushFakeServer(name: "server\(index)", log: log)
        }
        self.connections = connections
        self.servers = servers
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hedgerow-push-\(UUID().uuidString)", isDirectory: true)
        registry = PushRegistry(fileURL: registryFile ?? directory.appendingPathComponent("push-tags.json"))
        pigeonStore = InMemoryPigeonStore(
            registered ? PigeonRecord(registration: Self.relayDevice, token: "ab", lastSent: Date()) : nil
        )
        let tags = TagCounter()
        let frozen = servers
        manager = PushHandleManager(
            relay: PigeonClient(baseURL: PigeonClient.relayURL, transport: relay.transport),
            pigeonStore: pigeonStore, registry: registry,
            makeServer: { connection in
                frozen[connection.id].map {
                    PushServerClient(baseURL: connection.baseURL, token: "tok", transport: $0.transport)
                }
            },
            makeTag: { tags.next() },
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
    }

    func server(_ index: Int) -> PushFakeServer { servers[connections[index].id]! }
    func cleanUp() { try? FileManager.default.removeItem(at: directory) }
    func reconcile(
        wanted: Set<UUID>? = nil, connections list: [Connection]? = nil,
        blocked: @escaping @Sendable (UUID) -> PushConnectionStatus? = { _ in nil }
    ) async -> [UUID: PushConnectionStatus] {
        await manager.reconcile(
            connections: list ?? connections, wanted: wanted ?? Set((list ?? connections).map(\.id)), blocked: blocked
        )
    }
}

// MARK: - Lifecycle

@Suite struct PushHandleLifecycleTests {
    @Test func aHandleIsMadeAtTheRelayThenGivenToTheServerThenWrittenDown() async throws {
        let world = PushWorld()
        defer { world.cleanUp() }
        let connection = world.connections[0]

        let status = await world.manager.ensure(connection)

        #expect(status == .on)
        #expect(world.log.all == ["relay.create", "server0.register"])
        let entry = try #require(world.registry.entry(forConnection: connection.id))
        #expect(entry.tag == "tag1xxxxxxxxxxxxxxxxxx")
        #expect(entry.relayDeviceId == "hrd_device1")
        #expect(entry.relayHandleId == "h-1")
        #expect(world.registry.entry(forTag: entry.tag) == entry)
        // The server got the very handle the relay made, and the app did not keep it.
        let secret = try #require(world.relay.secret(of: "h-1"))
        #expect(world.server(0).handle(of: entry.serverDeviceId) == secret)
        let file = try String(contentsOf: world.directory.appendingPathComponent("push-tags.json"), encoding: .utf8)
        #expect(!file.contains(secret))
    }

    @Test func theTagGoesToTheRelayAsTheConnectionsTag() async throws {
        let world = PushWorld()
        defer { world.cleanUp() }
        _ = await world.manager.ensure(world.connections[0])
        let request = try #require(world.relay.transport.requests.first)
        let body = try #require(request.httpBody)
        #expect(try JSONSerialization.jsonObject(with: body) as? [String: String] == ["tag": "tag1xxxxxxxxxxxxxxxxxx"])
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer hrm_secret1")
    }

    @Test func aConnectionThatHasAHandleGetsNoSecondOne() async {
        let world = PushWorld()
        defer { world.cleanUp() }
        _ = await world.manager.ensure(world.connections[0])
        world.log.clear()

        #expect(await world.manager.ensure(world.connections[0]) == .on)
        #expect(world.log.all.isEmpty)
    }

    @Test func releasingTakesDownTheServerFirstThenTheRelay() async {
        let world = PushWorld()
        defer { world.cleanUp() }
        let connection = world.connections[0]
        _ = await world.manager.ensure(connection)
        let deviceId = world.registry.entry(forConnection: connection.id)!.serverDeviceId
        world.log.clear()

        await world.manager.release(connectionId: connection.id, connection: connection)

        #expect(world.log.all == ["server0.unregister \(deviceId)", "relay.revoke h-1"])
        #expect(world.registry.entries().isEmpty)
        #expect(world.server(0).deviceIds.isEmpty)
        #expect(world.relay.handleIds.isEmpty)
    }

    @Test func aServerThatCannotBeReachedDoesNotKeepTheRelaysHandleOrTheEntry() async {
        let world = PushWorld()
        defer { world.cleanUp() }
        let connection = world.connections[0]
        _ = await world.manager.ensure(connection)
        world.server(0).deleteStatus = 503
        world.log.clear()

        await world.manager.release(connectionId: connection.id, connection: connection)

        #expect(world.log.count("relay.revoke") == 1)
        #expect(world.registry.entries().isEmpty)
        #expect(world.relay.handleIds.isEmpty)
    }

    @Test func aRelayThatCannotBeReachedStillClearsTheEntryAfterTheServer() async {
        let world = PushWorld()
        defer { world.cleanUp() }
        let connection = world.connections[0]
        _ = await world.manager.ensure(connection)
        world.relay.revokeStatus = 503

        await world.manager.release(connectionId: connection.id, connection: connection)

        #expect(world.registry.entries().isEmpty)
        #expect(world.server(0).deviceIds.isEmpty)
        // The handle is still at the relay; the next launch finds it (see reconcile).
        #expect(world.relay.handleIds == ["h-1"])
    }

    @Test func aServerThatForgotTheDeviceCountsAsRemoved() async {
        let world = PushWorld()
        defer { world.cleanUp() }
        let connection = world.connections[0]
        _ = await world.manager.ensure(connection)
        world.server(0).deleteStatus = 404

        await world.manager.release(connectionId: connection.id, connection: connection)

        #expect(world.registry.entries().isEmpty)
        #expect(world.relay.handleIds.isEmpty)
    }

    @Test func releasingAConnectionThatIsAlreadyGoneOnlyTellsTheRelay() async {
        let world = PushWorld()
        defer { world.cleanUp() }
        let connection = world.connections[0]
        _ = await world.manager.ensure(connection)
        world.log.clear()

        await world.manager.release(connectionId: connection.id, connection: nil)

        #expect(world.log.all == ["relay.revoke h-1"])
        #expect(world.registry.entries().isEmpty)
    }

    @Test func releasingAConnectionWithNoHandleDoesNothing() async {
        let world = PushWorld()
        defer { world.cleanUp() }
        await world.manager.release(connectionId: world.connections[0].id, connection: world.connections[0])
        #expect(world.log.all.isEmpty)
    }

    @Test func turningNotificationsOffRevokesEveryHandle() async {
        let world = PushWorld(connectionCount: 3)
        defer { world.cleanUp() }
        for connection in world.connections { _ = await world.manager.ensure(connection) }
        #expect(world.relay.handleIds.count == 3)
        world.log.clear()
        world.server(1).deleteStatus = 503

        await world.manager.releaseAll(connections: world.connections)

        #expect(world.registry.entries().isEmpty)
        #expect(world.relay.handleIds.isEmpty)
        #expect(world.log.count("relay.revoke") == 3)
        #expect(world.server(0).deviceIds.isEmpty)
        #expect(world.server(2).deviceIds.isEmpty)
    }
}

// MARK: - Partial failures

@Suite struct PushHandleFailureTests {
    @Test func aServerWithPushOffGetsNoHandleAndTheRelaysIsRevoked() async {
        let world = PushWorld()
        defer { world.cleanUp() }
        world.server(0).registerStatus = 409
        world.server(0).registerCode = "push_disabled"

        let status = await world.manager.ensure(world.connections[0])

        #expect(status == .serverPushOff)
        #expect(world.log.all == ["relay.create", "server0.register", "relay.revoke h-1"])
        #expect(world.relay.handleIds.isEmpty)
        #expect(world.registry.entries().isEmpty)
    }

    @Test(arguments: [
        (409, "too_many_devices", PushConnectionStatus.tryLater),
        (409, "too_many_pending", PushConnectionStatus.tryLater),
        (429, "rate_limited", PushConnectionStatus.tryLater),
        (503, "overloaded", PushConnectionStatus.tryLater),
        (404, "not_found", PushConnectionStatus.serverNotReady),
        (403, "forbidden", PushConnectionStatus.serverNotReady),
        (401, "unauthorized", PushConnectionStatus.failed),
    ])
    func serverRefusalsAreStatusesAndLeaveNothingBehind(status: Int, code: String, expected: PushConnectionStatus) async {
        let world = PushWorld()
        defer { world.cleanUp() }
        world.server(0).registerStatus = status
        world.server(0).registerCode = code

        #expect(await world.manager.ensure(world.connections[0]) == expected)
        #expect(world.relay.handleIds.isEmpty)
        #expect(world.registry.entries().isEmpty)
    }

    @Test(arguments: [
        (429, PushConnectionStatus.tryLater), (409, PushConnectionStatus.tryLater),
        (404, PushConnectionStatus.tryLater), (503, PushConnectionStatus.tryLater),
        (401, PushConnectionStatus.failed),
    ])
    func relayRefusalsNeverReachTheServer(status: Int, expected: PushConnectionStatus) async {
        let world = PushWorld()
        defer { world.cleanUp() }
        world.relay.createStatus = status

        #expect(await world.manager.ensure(world.connections[0]) == expected)
        #expect(world.log.all == ["relay.create"])
        #expect(world.registry.entries().isEmpty)
    }

    @Test func aConnectionWithoutATokenGetsNothing() async {
        let world = PushWorld()
        defer { world.cleanUp() }
        // No server client can be made (no token in the Keychain).
        let manager = PushHandleManager(
            relay: PigeonClient(baseURL: PigeonClient.relayURL, transport: world.relay.transport),
            pigeonStore: world.pigeonStore, registry: world.registry, makeServer: { _ in nil }
        )
        #expect(await manager.ensure(world.connections[0]) == .failed)
        #expect(world.log.all.isEmpty)
    }

    @Test func withoutARelayRegistrationNothingIsSent() async {
        let world = PushWorld(registered: false)
        defer { world.cleanUp() }
        #expect(await world.manager.ensure(world.connections[0]) == .tryLater)
        #expect(world.log.all.isEmpty)
    }

    @Test func ifTheEntryCannotBeWrittenBothSidesAreUndone() async throws {
        // The registry file's folder is a file: writing fails.
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent("hedgerow-block-\(UUID().uuidString)")
        try Data("x".utf8).write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        let world = PushWorld(registryFile: blocker.appendingPathComponent("push-tags.json"))
        defer { world.cleanUp() }

        let status = await world.manager.ensure(world.connections[0])

        #expect(status == .failed)
        #expect(world.server(0).deviceIds.isEmpty)
        #expect(world.relay.handleIds.isEmpty)
    }

    @Test func aServerThatSaidNoIsNotAskedAgainInTheSameCall() async {
        // No loops: one try is one handle made and one server call.
        let world = PushWorld()
        defer { world.cleanUp() }
        world.server(0).registerStatus = 503
        _ = await world.manager.ensure(world.connections[0])
        #expect(world.log.count("relay.create") == 1)
        #expect(world.log.count("server0.register") == 1)
    }

    @Test func anEntryForAnEarlierRelayDeviceIsReplaced() async throws {
        let world = PushWorld()
        defer { world.cleanUp() }
        let connection = world.connections[0]
        _ = await world.manager.ensure(connection)
        let old = try #require(world.registry.entry(forConnection: connection.id))
        // The relay device was registered again.
        try world.pigeonStore.save(PigeonRecord(
            registration: PigeonRegistration(deviceId: "hrd_device2", manageKey: "hrm_secret2"), token: "cd", lastSent: Date()
        ))
        world.log.clear()

        #expect(await world.manager.ensure(connection) == .on)

        let fresh = try #require(world.registry.entry(forConnection: connection.id))
        #expect(fresh.relayDeviceId == "hrd_device2")
        #expect(fresh.tag != old.tag)
        #expect(world.log.all == ["server0.unregister \(old.serverDeviceId)", "relay.create", "server0.register"])
    }
}

// MARK: - At launch

@Suite struct PushReconcileTests {
    @Test func everyWantedConnectionGetsExactlyOneHandle() async {
        let world = PushWorld(connectionCount: 3)
        defer { world.cleanUp() }

        let result = await world.reconcile()

        #expect(result.values.allSatisfy { $0 == .on })
        #expect(result.count == 3)
        #expect(world.log.count("relay.create") == 3)
        #expect(world.registry.entries().count == 3)

        // A second launch changes nothing.
        world.log.clear()
        let again = await world.reconcile()
        #expect(again == result)
        #expect(world.log.all == ["relay.list"])
    }

    @Test func aHandleTheRelayNoLongerHasGetsAFreshOne() async throws {
        let world = PushWorld()
        defer { world.cleanUp() }
        let connection = world.connections[0]
        _ = await world.reconcile()
        let old = try #require(world.registry.entry(forConnection: connection.id))
        // The relay answered `gone` to the server, or the handle was revoked: it is not listed any more.
        world.relay.forget(old.relayHandleId)
        world.log.clear()

        let result = await world.reconcile()

        #expect(result[connection.id] == .on)
        let fresh = try #require(world.registry.entry(forConnection: connection.id))
        #expect(fresh.tag != old.tag)
        #expect(fresh.relayHandleId != old.relayHandleId)
        #expect(world.registry.entry(forTag: old.tag) == nil)
        #expect(world.log.all == ["relay.list", "server0.unregister \(old.serverDeviceId)", "relay.create", "server0.register"])
    }

    @Test func aHandleTheRegistryDoesNotKnowIsRevoked() async {
        let world = PushWorld()
        defer { world.cleanUp() }
        _ = await world.reconcile()
        world.relay.addUnknown("h-stray")
        world.log.clear()

        _ = await world.reconcile()

        #expect(world.log.all == ["relay.list", "relay.revoke h-stray"])
        #expect(world.relay.handleIds == ["h-1"])
    }

    @Test func aConnectionThatWasRemovedLosesItsHandleAtTheRelay() async {
        let world = PushWorld(connectionCount: 2)
        defer { world.cleanUp() }
        _ = await world.reconcile()
        let remaining = [world.connections[0]]
        world.log.clear()

        let result = await world.reconcile(connections: remaining)

        #expect(result == [world.connections[0].id: .on])
        #expect(world.registry.entries().count == 1)
        // The server cannot be told (no connection, no token), the relay can.
        #expect(world.log.all == ["relay.list", "relay.revoke h-2"])
        #expect(world.relay.handleIds == ["h-1"])
    }

    @Test func aConnectionSwitchedOffIsTakenDown() async {
        let world = PushWorld(connectionCount: 2)
        defer { world.cleanUp() }
        _ = await world.reconcile()
        world.log.clear()

        let result = await world.reconcile(wanted: [world.connections[0].id])

        #expect(result == [world.connections[0].id: .on])
        #expect(world.registry.entries().count == 1)
        #expect(world.log.count("server1.unregister") == 1)
        #expect(world.log.count("relay.revoke") == 1)
        #expect(world.server(1).deviceIds.isEmpty)
    }

    @Test func aConnectionThatFailedLatelyIsNotTriedAgain() async {
        let world = PushWorld(connectionCount: 2)
        defer { world.cleanUp() }
        let blockedId = world.connections[1].id

        let result = await world.reconcile(blocked: { $0 == blockedId ? .serverPushOff : nil })

        #expect(result[world.connections[0].id] == .on)
        #expect(result[blockedId] == .serverPushOff)
        #expect(world.log.count("relay.create") == 1)
        #expect(world.log.count("server1.") == 0)
    }

    @Test func aRelayThatSaysTheDeviceIsGoneMakesNoHandles() async {
        let world = PushWorld(connectionCount: 2)
        defer { world.cleanUp() }
        world.relay.listStatus = 404

        let result = await world.reconcile()

        #expect(result.values.allSatisfy { $0 == .tryLater })
        #expect(world.log.all == ["relay.list"])
    }

    @Test func aRelayThatIsBusyStillGetsTheHandlesButNoCleaning() async {
        let world = PushWorld()
        defer { world.cleanUp() }
        _ = await world.reconcile()
        world.relay.listStatus = 503
        world.relay.addUnknown("h-stray")
        world.log.clear()

        let result = await world.reconcile()

        #expect(result[world.connections[0].id] == .on)
        #expect(world.log.all == ["relay.list"])
        #expect(world.relay.handleIds.contains("h-stray"))
    }

    @Test func aRelayDeviceThatWasRegisteredAgainMakesFreshHandles() async throws {
        let world = PushWorld()
        defer { world.cleanUp() }
        _ = await world.reconcile()
        try world.pigeonStore.save(PigeonRecord(
            registration: PigeonRegistration(deviceId: "hrd_device2", manageKey: "hrm_secret2"), token: "cd", lastSent: Date()
        ))
        world.relay.forget("h-1")
        world.log.clear()

        let result = await world.reconcile()

        #expect(result[world.connections[0].id] == .on)
        #expect(world.registry.entry(forConnection: world.connections[0].id)?.relayDeviceId == "hrd_device2")
        #expect(world.log.count("relay.create") == 1)
    }

    @Test func theHourlyLimitIsAStatusNotALoop() async {
        let world = PushWorld(connectionCount: 3)
        defer { world.cleanUp() }
        world.relay.createStatus = 429

        let result = await world.reconcile()

        #expect(result.values.allSatisfy { $0 == .tryLater })
        // One try per connection; nothing retried.
        #expect(world.log.count("relay.create") == 3)
        #expect(world.log.count("server") == 0)
    }

    @Test func withoutARelayRegistrationEveryConnectionWaits() async {
        let world = PushWorld(connectionCount: 2, registered: false)
        defer { world.cleanUp() }
        let result = await world.reconcile()
        #expect(result.values.allSatisfy { $0 == .tryLater })
        #expect(world.log.all.isEmpty)
    }
}
