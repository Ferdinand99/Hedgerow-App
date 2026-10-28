import Foundation

/// Keeps one push handle per connection: made at the relay, given to the connection's server,
/// remembered in the `PushRegistry`; and taken down again the other way round.
///
/// - Setting up: tag, then the relay's handle, then the server's registration. If the server says
///   no, the relay's handle is revoked again at once (the relay allows 32 handles per device and
///   10 new ones an hour).
/// - Taking down: the local entry goes first, then the relay's handle (that stops the pushes), then
///   the server's registration. A step that fails does not stop the next one, and the entry is gone either way. What a
///   failed step leaves behind is cleaned up later: a handle nobody has in the registry is revoked by
///   `reconcile`, and a server that is pushed to a revoked handle forgets it on `gone`.
/// - Nothing here loops. A failure is a status; the caller decides when to try again (next launch).
///
/// Callers run the methods one after the other (the app's push controller queues them).
public actor PushHandleManager {
    public typealias ServerFactory = @Sendable (Connection) -> PushServerClient?

    private let relay: PigeonClient
    private let pigeonStore: any PigeonStore
    private let registry: PushRegistry
    private let makeServer: ServerFactory
    private let makeTag: @Sendable () -> String
    private let now: @Sendable () -> Date
    /// Handles made at the relay that are not in the registry yet.
    private var inFlight: Set<String> = []

    public init(
        relay: PigeonClient, pigeonStore: any PigeonStore, registry: PushRegistry, makeServer: @escaping ServerFactory
    ) {
        self.init(
            relay: relay, pigeonStore: pigeonStore, registry: registry, makeServer: makeServer,
            makeTag: { PushTag.generate() }, now: { Date() }
        )
    }

    init(
        relay: PigeonClient, pigeonStore: any PigeonStore, registry: PushRegistry, makeServer: @escaping ServerFactory,
        makeTag: @escaping @Sendable () -> String, now: @escaping @Sendable () -> Date
    ) {
        self.relay = relay
        self.pigeonStore = pigeonStore
        self.registry = registry
        self.makeServer = makeServer
        self.makeTag = makeTag
        self.now = now
    }

    private func registration() -> PigeonRegistration? {
        (try? pigeonStore.load())?.registration
    }

    // MARK: Setting up

    /// Makes sure `connection` has a handle that the relay and the server know. With one already
    /// (made for this relay device) nothing is sent.
    public func ensure(_ connection: Connection) async -> PushConnectionStatus {
        // No registration at the relay (yet): the app registers the device first, then asks again.
        guard let registration = registration() else { return .relayReset }
        if let entry = registry.entry(forConnection: connection.id) {
            if entry.relayDeviceId == registration.deviceId { return .on }
            // Made for a relay device that is gone: the handle is dead. Take down what is left.
            try? registry.remove(connectionId: connection.id)
            await unregisterAtServer(entry, connection: connection)
        }
        guard let server = makeServer(connection) else { return .failed }

        let tag = makeTag()
        let handle: PigeonHandle
        do {
            handle = try await relay.createHandle(registration, tag: tag)
        } catch {
            return PushConnectionStatus(error: error)
        }
        inFlight.insert(handle.handleId)
        defer { inFlight.remove(handle.handleId) }

        let device: PushServerDevice
        do {
            device = try await server.register(handle: handle.handle)
        } catch {
            // The server will not have it: do not leave the handle at the relay.
            await revokeAtRelay(handle.handleId, registration: registration)
            return PushConnectionStatus(error: error)
        }

        let entry = PushEntry(
            tag: tag, connectionId: connection.id, relayDeviceId: registration.deviceId,
            relayHandleId: handle.handleId, serverDeviceId: device.id, created: now()
        )
        do {
            try registry.save(entry)
        } catch {
            // Without the entry a push could not be tied to a connection.
            try? await server.unregister(deviceId: device.id)
            await revokeAtRelay(handle.handleId, registration: registration)
            return .failed
        }
        return .on
    }

    /// The connection's token was replaced. The server drops the devices that were registered with the
    /// old token, so the handle it has is dead although the registry still lists it: take it down
    /// (the server's answer to the delete may well be `404`, which counts as removed) and make a new one.
    public func renew(_ connection: Connection) async -> PushConnectionStatus {
        await release(connectionId: connection.id, connection: connection)
        return await ensure(connection)
    }

    // MARK: Taking down

    /// Push is off for this connection, or the connection is going away. `connection` is `nil` when
    /// it is already gone from the list (then only the relay can be told).
    public func release(connectionId: UUID, connection: Connection?) async {
        guard let entry = registry.entry(forConnection: connectionId) else { return }
        try? registry.remove(connectionId: connectionId)
        await takeDown(entry, connection: connection)
    }

    /// Notifications are off for the device: every handle goes.
    public func releaseAll(connections: [Connection]) async {
        let entries = registry.entries()
        try? registry.removeAll()
        for entry in entries {
            await takeDown(entry, connection: connections.first { $0.id == entry.connectionId })
        }
    }

    private func takeDown(_ entry: PushEntry, connection: Connection?) async {
        // The relay first: that is what stops the pushes. Then the server forgets the device.
        if let registration = registration(), registration.deviceId == entry.relayDeviceId {
            await revokeAtRelay(entry.relayHandleId, registration: registration)
        }
        // A handle of another relay device died with that device.
        await unregisterAtServer(entry, connection: connection)
    }

    private func unregisterAtServer(_ entry: PushEntry, connection: Connection?) async {
        guard let connection, let server = makeServer(connection) else { return }
        try? await server.unregister(deviceId: entry.serverDeviceId)
    }

    private func revokeAtRelay(_ handleId: String, registration: PigeonRegistration) async {
        try? await relay.revokeHandle(registration, handleId: handleId)
    }

    // MARK: Launch

    /// Brings the registry, the relay and the connections in line, once per launch:
    /// - an entry for a connection that is gone, or switched off, is taken down;
    /// - an entry the relay no longer has (`gone`, or revoked) or that belongs to an earlier relay
    ///   device is dropped, so the connection gets a fresh handle below;
    /// - a handle at the relay that the registry does not know (a step failed earlier) is revoked;
    /// - every connection in `wanted` without an entry gets one, unless `blocked` says it was tried
    ///   lately and why it did not work.
    ///
    /// Returns the status of each connection in `wanted`.
    public func reconcile(
        connections: [Connection], wanted: Set<UUID>, blocked: @Sendable (UUID) -> PushConnectionStatus?
    ) async -> [UUID: PushConnectionStatus] {
        guard let registration = registration() else {
            return Dictionary(uniqueKeysWithValues: wanted.map { ($0, PushConnectionStatus.relayReset) })
        }

        // What the relay still has. Failing to ask only means no cleaning this time.
        var live: Set<String>?
        do {
            live = Set(try await relay.listHandles(registration).map(\.handleId))
        } catch PigeonError.gone {
            // The relay device is gone (or its manage key is refused): the app registers it again,
            // and every entry is then stale. Nothing to make a handle on now.
            return Dictionary(uniqueKeysWithValues: wanted.map { ($0, PushConnectionStatus.relayReset) })
        } catch PigeonError.invalidCredentials {
            return Dictionary(uniqueKeysWithValues: wanted.map { ($0, PushConnectionStatus.relayReset) })
        } catch {
            live = nil
        }

        // Handles dealt with below are not orphans, whatever the listing above said.
        var handled: Set<String> = []
        for entry in registry.entries() {
            handled.insert(entry.relayHandleId)
            let connection = connections.first { $0.id == entry.connectionId }
            if connection == nil || !wanted.contains(entry.connectionId) {
                try? registry.remove(connectionId: entry.connectionId)
                await takeDown(entry, connection: connection)
            } else if entry.relayDeviceId != registration.deviceId || (live.map { !$0.contains(entry.relayHandleId) } ?? false) {
                try? registry.remove(connectionId: entry.connectionId)
                await unregisterAtServer(entry, connection: connection)
            }
        }

        if let live {
            let known = Set(registry.entries().map(\.relayHandleId)).union(inFlight).union(handled)
            for handleId in live.subtracting(known) {
                await revokeAtRelay(handleId, registration: registration)
            }
        }

        var result: [UUID: PushConnectionStatus] = [:]
        for connection in connections where wanted.contains(connection.id) {
            if registry.entry(forConnection: connection.id) != nil {
                result[connection.id] = .on
            } else if let status = blocked(connection.id) {
                result[connection.id] = status
            } else {
                result[connection.id] = await ensure(connection)
            }
        }
        return result
    }
}
