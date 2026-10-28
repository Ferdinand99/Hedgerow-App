import HedgerowCore
import SwiftUI

/// The "Notifications" section of Settings: the switch, what state it is in, a switch for each
/// connection (once this device is registered with the push service) and the device id.
struct NotificationsSection: View {
    let store: ConnectionStore
    @Environment(PushController.self) private var push

    var body: some View {
        Section {
            Toggle("Notifications", isOn: Binding(get: { push.isOn }, set: { push.setEnabled($0) }))

            Text(statusText)
                .font(.footnote)
                .foregroundStyle(.secondary)

            if push.phase == .denied {
                Button("Open Settings") { push.openSystemSettings() }
            }

            // One switch per connection: each server sends its own notifications.
            if push.phase == .registered, !store.connections.isEmpty {
                Text("Send notifications from")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(store.connections) { connection in
                    ConnectionPushRow(connection: connection)
                }
            }

            // Not a secret: it only lets the push service find this device.
            if push.isOn, let deviceId = push.deviceId {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Device ID")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(verbatim: deviceId)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                }
            }
        } header: {
            Text("Notifications")
        } footer: {
            if push.isOn, push.deviceId != nil {
                Text("Used to send a test notification from the push service.")
            }
        }
    }

    private var statusText: LocalizedStringKey {
        switch push.phase {
        case .off: "Notifications are off."
        case .asking: "Asking for permission…"
        case .registering: "Registering this device…"
        case .registered: "Notifications are on."
        case .denied: "Notifications are turned off for Hedgerow in iOS Settings."
        case .unreachable: "Couldn't reach the push service, will try again."
        case .failed: "Something went wrong with the push service. Hedgerow will try again the next time it opens."
        }
    }
}

/// A connection's switch, and (when push is not working for it) why, in calm words.
private struct ConnectionPushRow: View {
    let connection: Connection
    @Environment(PushController.self) private var push

    var body: some View {
        let status = push.status(for: connection.id)
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(
                get: { push.status(for: connection.id) != .off },
                set: { push.setConnection(connection, on: $0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(connection.displayName)
                    Text(verbatim: "\(connection.kind.displayName) · \(connection.baseURL.host() ?? connection.baseURL.absoluteString)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let message = Self.message(for: status) {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static func message(for status: PushConnectionStatus) -> LocalizedStringKey? {
        switch status {
        case .off, .on: nil
        case .working: "Setting up…"
        case .serverPushOff: "This server hasn't turned on push. Add the Hedgerow app channel to its notifications."
        case .serverNotReady: "This server can't send push yet. It may need an update."
        case .tryLater: "Couldn't set this up right now. Hedgerow will try again later."
        case .failed: "Couldn't set this up. Hedgerow will try again the next time it opens."
        }
    }
}
