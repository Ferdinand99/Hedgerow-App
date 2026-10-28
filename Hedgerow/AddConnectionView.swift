import HedgerowCore
import SwiftUI

struct AddConnectionView: View {
    let store: ConnectionStore

    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var token = ""
    @State private var name = ""
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var task: Task<Void, Never>?

    /// Longest a connect or a token check may take before the sheet says it can't reach the address.
    static let deadline: Duration = .seconds(30)

    private var canConnect: Bool {
        !address.trimmingCharacters(in: .whitespaces).isEmpty
            && !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isWorking
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Address", text: $address, prompt: Text(verbatim: "https://vole.example.com"))
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("Plain http is only accepted for addresses on your own network (LAN, Tailscale). Everything else needs https.")
                }

                Section {
                    SecureField("API token", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Name (optional)", text: $name)
                } footer: {
                    Text("Use a read-only token if you can. It is stored in this device's Keychain and only sent to the address above.")
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button(action: connect) {
                        HStack {
                            Text(isWorking ? "Connecting…" : "Connect")
                            if isWorking { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(!canConnect)
                }
            }
            .navigationTitle("Add a service")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // Allowed while working: it stops the request and stores nothing.
                    Button("Cancel") {
                        task?.cancel()
                        dismiss()
                    }
                }
            }
            // A half-finished connect must not be left running behind a closed sheet
            // (Cancel, swipe down or anything else that removes it).
            .onDisappear { task?.cancel() }
        }
    }

    private func connect() {
        guard let url = parseServiceAddress(address) else {
            errorMessage = String(localized: "Enter a valid address, for example https://vole.example.com")
            return
        }
        errorMessage = nil
        isWorking = true
        let service = store, secret = token, label = name
        task = Task { @MainActor in
            defer { isWorking = false }
            do {
                // The whole connect (detect + check the token) gets one deadline, so a slow
                // server can't trap the sheet.
                try await withDeadline(Self.deadline) {
                    try await service.add(url: url, token: secret, name: label)
                }
                dismiss()
            } catch is CancellationError {
                // Cancelled by the person: nothing to say.
            } catch {
                errorMessage = userMessage(for: error)
            }
        }
    }
}

/// "Replace token" on a card or in the connection list: the new token is checked against the
/// service first, so a wrong one never replaces a working one.
struct ReplaceTokenView: View {
    let store: ConnectionStore
    let connection: Connection

    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("New API token", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text(verbatim: "\(connection.displayName) · \(connection.kind.displayName)")
                } footer: {
                    Text("Use a read-only token if you can. It is stored in this device's Keychain and only sent to the address of this service.")
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button(action: save) {
                        HStack {
                            Text("Save")
                            if isWorking { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isWorking)
                }
            }
            .navigationTitle("Replace token")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // Allowed while working: it stops the request and stores nothing.
                    Button("Cancel") {
                        task?.cancel()
                        dismiss()
                    }
                }
            }
            .onDisappear { task?.cancel() }
        }
    }

    private func save() {
        errorMessage = nil
        isWorking = true
        let service = store, id = connection.id, secret = token, replaced = connection
        task = Task { @MainActor in
            defer { isWorking = false }
            do {
                try await withDeadline(AddConnectionView.deadline) {
                    try await service.verifyToken(secret, for: id)
                }
                // Cancelled while the check was finishing: keep the old token.
                try Task.checkCancellation()
                try service.replaceToken(id, token: secret)
                // The server drops the devices registered with the old token: push needs a new handle.
                PushController.shared.tokenWasReplaced(replaced)
                dismiss()
            } catch is CancellationError {
                // Cancelled by the person: nothing to say.
            } catch {
                errorMessage = userMessage(for: error)
            }
        }
    }
}
