import Foundation

/// How push stands for one connection. Shown in Settings under Notifications.
public enum PushConnectionStatus: String, Codable, Sendable, Equatable {
    /// The person switched push off for this connection.
    case off
    /// Being set up or taken down.
    case working
    /// The server has this device's handle.
    case on
    /// `409 push_disabled`: the server has no "Hedgerow app" channel, so it sends nothing.
    case serverPushOff
    /// The server answered as one that has no push (an older version), or refused the token for it.
    case serverNotReady
    /// The relay does not know this device any more (`gone`), refused its manage key, or the device has
    /// no registration yet. The app registers the device again and then makes the handles; nothing to
    /// wait an hour for, so this is never remembered as a problem.
    case relayReset
    /// A limit or a busy relay or server (`409 too_many_*`, `429`, `503`, no connection): calm, tried again later.
    case tryLater
    /// Anything else (the token was refused, an answer the app does not understand).
    case failed

    /// What an error from the relay or from the server means for the person.
    public init(error: Error) {
        switch error {
        case let error as PigeonError:
            switch error {
            case .gone, .invalidCredentials: self = .relayReset
            case .rateLimited, .limitReached, .unavailable: self = .tryLater
            case .insecureURL, .unexpected: self = .failed
            }
        case let error as PushServerError:
            switch error {
            case .pushDisabled: self = .serverPushOff
            case .notSupported, .forbidden: self = .serverNotReady
            case .tooManyDevices, .tooManyPending, .rateLimited, .unavailable: self = .tryLater
            case .unauthorized, .notFound, .insecureURL, .unexpected: self = .failed
            }
        case is CancellationError:
            self = .tryLater
        default:
            self = .failed
        }
    }

    /// The result is worth remembering for an hour (see `PushBackoff`).
    public var isProblem: Bool {
        switch self {
        case .serverPushOff, .serverNotReady, .tryLater, .failed: true
        case .off, .working, .on, .relayReset: false
        }
    }
}
