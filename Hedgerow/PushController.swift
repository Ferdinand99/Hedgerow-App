import HedgerowCore
import Observation
import UIKit
import UserNotifications

/// Notifications on or off, this device's registration with Postal Pigeon (the push relay) and one
/// push handle per connection.
///
/// The APNs device token and the relay's manage key never leave this file's callers' hands:
/// the token goes straight to `PigeonRegistrar`, which keeps the registration in the Keychain
/// (this device only). Nothing here logs or shows them. Only the device id (`hrd_…`, not secret)
/// is shown, so it can be used to send a test notification.
///
/// With notifications on, each connection gets a handle once (`PushHandleManager`): made at the relay,
/// given to that connection's server, and noted in the tag registry in the App Group container (no
/// secrets). A switch per connection turns it off again. A failure is a calm status and is tried
/// again on the next launch, never in a loop (the relay allows 10 new handles an hour).
@MainActor @Observable
final class PushController {
    static let shared = PushController()

    enum Phase: Equatable {
        case off
        /// The iOS permission prompt is up.
        case asking
        /// Waiting for Apple's token or the relay's answer.
        case registering
        case registered
        /// Not allowed in iOS Settings (refused in the prompt, or turned off there later).
        case denied
        /// The relay (or Apple) could not be reached or is busy. Tried again on the next launch.
        case unreachable
        case failed
    }

    /// A tap on a notification: the tabs show this connection.
    struct OpenRequest: Equatable {
        let id = UUID()
        let connectionId: UUID
    }

    private(set) var phase: Phase = .off
    /// The relay's id for this device; not a secret.
    private(set) var deviceId: String?
    /// How push stands for each connection. Only meaningful while `phase` is `.registered`.
    private(set) var statuses: [UUID: PushConnectionStatus] = [:]
    /// Set by a tap on a notification, cleared by the root view once it has shown the connection.
    private(set) var openRequest: OpenRequest?

    /// The person's choice: on, even while iOS Settings has notifications off.
    @ObservationIgnored private var wantsNotifications: Bool {
        didSet { defaults.set(wantsNotifications, forKey: Self.enabledKey) }
    }

    private static let enabledKey = "push.enabled"
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let registrar: PigeonRegistrar
    @ObservationIgnored private let manager: PushHandleManager
    @ObservationIgnored private let preferences: PushPreferences
    @ObservationIgnored private let backoff: PushBackoff
    @ObservationIgnored private let presenter = ForegroundPresenter()
    @ObservationIgnored private var store: ConnectionStore?
    /// The device was registered again once in this launch because the relay did not know it. A second
    /// time is not tried: a relay that keeps saying so gets the next launch.
    @ObservationIgnored private var reregisteredThisLaunch = false
    /// The calls to the registrar and the manager run one after the other.
    @ObservationIgnored private var queue: Task<Void, Never>?

    #if DEBUG
    private static let environment = PigeonEnvironment.sandbox
    #else
    private static let environment = PigeonEnvironment.production
    #endif

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        wantsNotifications = defaults.bool(forKey: Self.enabledKey)
        preferences = PushPreferences(defaults: defaults)
        backoff = PushBackoff(defaults: defaults)
        registrar = PigeonRegistrar(
            client: PigeonClient(), store: AppStorageLocation.makePigeonStore(), environment: Self.environment
        )
        let vault = AppStorageLocation.makeVault()
        manager = PushHandleManager(
            relay: PigeonClient(),
            pigeonStore: AppStorageLocation.makePigeonStore(),
            registry: PushRegistry(fileURL: AppStorageLocation.pushRegistryFile),
            makeServer: { connection in
                // The token is read for this one call and goes straight into the request.
                guard let token = try? vault.token(for: connection.id), !token.isEmpty else { return nil }
                return PushServerClient(baseURL: connection.baseURL, token: token)
            }
        )
    }

    /// What the toggle shows. A refusal in iOS Settings counts as off.
    var isOn: Bool {
        phase != .off && phase != .denied
    }

    // MARK: Launch and return

    /// Called once from the app delegate when the app starts.
    func start() {
        UNUserNotificationCenter.current().delegate = presenter
        guard wantsNotifications else { return }
        // Shown as on straight away, so the toggle doesn't flicker while iOS answers.
        phase = .registering
        Task {
            let stored = await registrar.storedDeviceId()
            let status = await currentAuthorization()
            // The toggle may have been turned off meanwhile.
            guard wantsNotifications, phase == .registering else { return }
            switch status {
            case .denied:
                deviceId = stored
                phase = .denied
            case .notDetermined:
                // The choice was made before this install (or never prompted): start from off.
                wantsNotifications = false
                phase = .off
            default:
                deviceId = stored
                beginRegistration()
            }
        }
    }

    /// The person may have come back from iOS Settings, where notifications can be turned on again
    /// or off while the app keeps running.
    func returnedToApp() {
        guard phase != .off, phase != .asking else { return }
        Task {
            let status = await currentAuthorization()
            guard phase != .off, phase != .asking else { return }
            if status == .denied || status == .notDetermined {
                // Turned off in iOS Settings: shown as off; the registration is kept for when it
                // is allowed again.
                phase = .denied
            } else if phase == .denied {
                if wantsNotifications {
                    beginRegistration()
                } else {
                    phase = .off
                }
            }
        }
    }

    // MARK: Toggle

    func setEnabled(_ on: Bool) {
        if on { enable() } else { disable() }
    }

    private func enable() {
        guard phase == .off || phase == .denied else { return }
        phase = .asking
        Task {
            var status = await currentAuthorization()
            if status == .notDetermined {
                status = await requestAuthorization() ? .authorized : .denied
            }
            // The toggle may have been turned off while the prompt was up.
            guard phase == .asking else { return }
            if status == .denied {
                phase = .denied
                return
            }
            wantsNotifications = true
            beginRegistration()
        }
    }

    private func disable() {
        wantsNotifications = false
        phase = .off
        deviceId = nil
        statuses = [:]
        let connections = store?.connections ?? []
        let manager = manager
        enqueue { [self] in
            // Every handle goes first (it takes the relay registration and the tokens to do that), then
            // the device. Off is final locally even when the relay or a server cannot be reached
            // (the entries are gone first, and the registrar clears the Keychain either way).
            _ = try? await withDeadline(.seconds(12)) { await manager.releaseAll(connections: connections) }
            await registrar.disable()
            if !wantsNotifications {
                UIApplication.shared.unregisterForRemoteNotifications()
            }
        }
    }

    func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: Registration

    private func beginRegistration() {
        if phase != .registered { phase = .registering }
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// Apple handed out the token (on every launch, and when it changes).
    func didRegister(deviceToken: Data) {
        guard wantsNotifications else { return }
        enqueue { [self] in
            do {
                let registration = try await registrar.apply(token: deviceToken)
                guard wantsNotifications else { return }
                deviceId = registration.deviceId
                // A new relay device (registered again): what was held back for the old one is moot.
                backoff.noteRelayDevice(registration.deviceId)
                phase = .registered
                syncConnections()
            } catch is CancellationError {
                // Nothing to show; the next launch tries again.
            } catch {
                guard wantsNotifications else { return }
                phase = Self.phase(for: error)
            }
        }
    }

    func didFailToRegister() {
        guard wantsNotifications, phase != .registered else { return }
        phase = .unreachable
    }

    private static func phase(for error: Error) -> Phase {
        guard let error = error as? PigeonError else { return .failed }
        switch error {
        case .rateLimited, .unavailable: return .unreachable
        default: return .failed
        }
    }

    // MARK: Handles per connection

    /// The connection list is open (once per launch, and again after "Reset connections"). Push for
    /// the connections starts when the device is registered.
    func attach(_ store: ConnectionStore) {
        self.store = store
        // Choices and waiting times for connections that are gone (removed on another launch, or the
        // list was reset) are forgotten. Only a list that could be read gets here.
        let ids = Set(store.connections.map(\.id))
        preferences.purge(keeping: ids)
        backoff.purge(keeping: ids)
        syncConnections()
    }

    /// Brings the handles in line with the connections: one for each connection that is switched on,
    /// none for one that was removed or switched off. Called when the device is registered and when
    /// the list of connections changes. A connection that failed lately is not tried again for an hour.
    func syncConnections() {
        guard phase == .registered, wantsNotifications, store != nil else { return }
        enqueue { [self] in
            guard phase == .registered, wantsNotifications, let store else { return }
            let connections = store.connections
            let wanted = Set(connections.map(\.id).filter { preferences.isOn($0) })
            let backoff = backoff
            let heldBack = Set(wanted.filter { backoff.blocked($0) != nil })
            for id in wanted where statuses[id] == nil { statuses[id] = .working }

            let result = await manager.reconcile(
                connections: connections, wanted: wanted, blocked: { backoff.blocked($0) }
            )
            guard phase == .registered, wantsNotifications else { return }

            var next: [UUID: PushConnectionStatus] = [:]
            for (id, status) in result where preferences.isOn(id) {
                next[id] = status
                // A result that was only remembered does not start a new hour.
                if !heldBack.contains(id) { remember(status, for: id) }
            }
            statuses = next
            reregisterIfTheRelayLostTheDevice(in: next)
        }
    }

    /// The relay says it does not know this device, or refuses its manage key: register the device
    /// again right away (Apple hands the token over again, `didRegister` makes a new registration
    /// and then the handles) instead of waiting for the daily keep-alive to find out. Once per launch.
    /// If it happens again the connections show "try later", and the next launch tries.
    private func reregisterIfTheRelayLostTheDevice(in results: [UUID: PushConnectionStatus]) {
        guard results.values.contains(.relayReset) else { return }
        guard !reregisteredThisLaunch else {
            for (id, status) in results where status == .relayReset {
                statuses[id] = .tryLater
                backoff.record(id, status: .tryLater)
            }
            return
        }
        reregisteredThisLaunch = true
        phase = .registering
        deviceId = nil
        enqueue { [self] in
            await registrar.reregister()
            guard wantsNotifications else { return }
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    /// How push stands for a connection, as Settings shows it.
    func status(for id: UUID) -> PushConnectionStatus {
        let known = statuses[id]
        guard preferences.isOn(id) else { return .off }
        return known ?? .working
    }

    /// The switch of one connection.
    func setConnection(_ connection: Connection, on: Bool) {
        preferences.set(connection.id, on: on)
        guard phase == .registered else { return }
        // A hand-made change always tries; the relay's own limits still apply.
        backoff.clear(connection.id)
        let manager = manager
        if on {
            statuses[connection.id] = .working
            enqueue { [self] in
                guard phase == .registered, wantsNotifications, preferences.isOn(connection.id) else { return }
                let status = await manager.ensure(connection)
                // Switched off while this ran: the release that follows in the queue cleans up.
                guard preferences.isOn(connection.id) else { return }
                statuses[connection.id] = status
                remember(status, for: connection.id)
                reregisterIfTheRelayLostTheDevice(in: [connection.id: status])
            }
        } else {
            statuses[connection.id] = .off
            enqueue { await manager.release(connectionId: connection.id, connection: connection) }
        }
    }

    /// The token of a connection was replaced. The server drops the devices that were registered with
    /// the old token, so the handle it had is dead even though it is still on file: take it down and
    /// make a new one with the new token. Nothing happens for a connection that is switched off.
    func tokenWasReplaced(_ connection: Connection) {
        guard phase == .registered, preferences.isOn(connection.id) else { return }
        backoff.clear(connection.id)
        statuses[connection.id] = .working
        let manager = manager
        enqueue { [self] in
            guard phase == .registered, wantsNotifications, preferences.isOn(connection.id) else { return }
            let status = await manager.renew(connection)
            guard preferences.isOn(connection.id) else { return }
            statuses[connection.id] = status
            remember(status, for: connection.id)
            reregisterIfTheRelayLostTheDevice(in: [connection.id: status])
        }
    }

    /// A connection is about to be removed: the relay revokes the handle (that stops the pushes) and
    /// its server forgets this device. It has to come first, because it needs the connection's token.
    /// A server that cannot be reached does not hold the removal up for long, and the local entry is
    /// cleared either way. The person's choices for the connection are kept until the removal worked
    /// (`connectionWasRemoved`).
    func connectionWillBeRemoved(_ connection: Connection) async {
        statuses[connection.id] = .working
        backoff.clear(connection.id)
        let manager = manager
        let task = enqueue {
            _ = try? await withDeadline(.seconds(8)) {
                await manager.release(connectionId: connection.id, connection: connection)
            }
        }
        await task.value
    }

    /// The removal worked: the connection's choices and status go too.
    func connectionWasRemoved(_ id: UUID) {
        statuses[id] = nil
        backoff.clear(id)
        preferences.set(id, on: true)
    }

    private func remember(_ status: PushConnectionStatus, for id: UUID) {
        if status.isProblem {
            backoff.record(id, status: status)
        } else {
            backoff.clear(id)
        }
    }

    // MARK: Tap on a notification

    func openConnection(_ id: UUID) {
        openRequest = OpenRequest(connectionId: id)
    }

    func clearOpenRequest() {
        openRequest = nil
    }

    @discardableResult
    private func enqueue(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = queue
        let task = Task {
            await previous?.value
            await operation()
        }
        queue = task
        return task
    }
}

// MARK: - iOS permission

private func currentAuthorization() async -> UNAuthorizationStatus {
    await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
}

private func requestAuthorization() async -> Bool {
    (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
}

/// A notification that arrives while the app is open is shown as a banner with sound. A tap on one
/// opens the tab of the connection it came from.
final class ForegroundPresenter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        let content = response.notification.request.content
        guard let id = Self.connectionId(userInfo: content.userInfo, threadIdentifier: content.threadIdentifier) else {
            return
        }
        await MainActor.run { PushController.shared.openConnection(id) }
    }

    /// Which of the app's own connections a notification belongs to. The payload is only used as a
    /// key: its tag is looked up in the app's registry. The extension also puts the connection id
    /// in the thread identifier, which is used when the tag is not there (the root view still checks
    /// that the connection exists, and nothing else is read from the notification).
    static func connectionId(userInfo: [AnyHashable: Any], threadIdentifier: String) -> UUID? {
        if case .v1(let push) = PushPayload.parse(userInfo),
           let entry = PushRegistry(fileURL: AppStorageLocation.pushRegistryFile).entry(forTag: push.tag) {
            return entry.connectionId
        }
        return UUID(uuidString: threadIdentifier)
    }
}

// MARK: - App delegate

/// SwiftUI has no hooks for the APNs callbacks, so a delegate passes them on.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        PushController.shared.start()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushController.shared.didRegister(deviceToken: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        PushController.shared.didFailToRegister()
    }

    /// `sync` pushes (silent): nothing to fetch yet.
    func application(
        _ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        completionHandler(.noData)
    }
}
