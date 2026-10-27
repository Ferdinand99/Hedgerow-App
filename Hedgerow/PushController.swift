import HedgerowCore
import Observation
import UIKit
import UserNotifications

/// Notifications on or off, and this device's registration with Postal Pigeon (the push relay).
///
/// The APNs device token and the relay's manage key never leave this file's callers' hands:
/// the token goes straight to `PigeonRegistrar`, which keeps the registration in the Keychain
/// (this device only). Nothing here logs or shows them. Only the device id (`hrd_…`, not secret)
/// is shown, so it can be used to send a test notification.
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

    private(set) var phase: Phase = .off
    /// The relay's id for this device; not a secret.
    private(set) var deviceId: String?

    /// The person's choice: on, even while iOS Settings has notifications off.
    @ObservationIgnored private var wantsNotifications: Bool {
        didSet { defaults.set(wantsNotifications, forKey: Self.enabledKey) }
    }

    private static let enabledKey = "push.enabled"
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let registrar: PigeonRegistrar
    @ObservationIgnored private let presenter = ForegroundPresenter()
    /// The calls to the registrar run one after the other.
    @ObservationIgnored private var queue: Task<Void, Never>?

    #if DEBUG
    private static let environment = PigeonEnvironment.sandbox
    #else
    private static let environment = PigeonEnvironment.production
    #endif

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        wantsNotifications = defaults.bool(forKey: Self.enabledKey)
        registrar = PigeonRegistrar(
            client: PigeonClient(), store: AppStorageLocation.makePigeonStore(), environment: Self.environment
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
        Task {
            let stored = await registrar.storedDeviceId()
            switch await currentAuthorization() {
            case .denied:
                deviceId = stored
                phase = .denied
            case .notDetermined:
                // The choice was made before this install (or never prompted): start from off.
                wantsNotifications = false
            default:
                deviceId = stored
                beginRegistration()
            }
        }
    }

    /// The person may have come back from iOS Settings.
    func returnedToApp() {
        guard phase == .denied else { return }
        Task {
            switch await currentAuthorization() {
            case .denied, .notDetermined:
                break
            default:
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
        enqueue { [self] in
            // Off is final locally even when the relay cannot be reached (the registrar clears the
            // Keychain either way).
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
                phase = .registered
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

    private func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        let previous = queue
        queue = Task {
            await previous?.value
            await operation()
        }
    }
}

// MARK: - iOS permission

private func currentAuthorization() async -> UNAuthorizationStatus {
    await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
}

private func requestAuthorization() async -> Bool {
    (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
}

/// A notification that arrives while the app is open is shown as a banner with sound.
final class ForegroundPresenter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
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
