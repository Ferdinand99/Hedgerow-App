import SwiftUI

/// The "Notifications" section of Settings: the switch, what state it is in, and (once this
/// device is registered with the push service) the device id.
struct NotificationsSection: View {
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
