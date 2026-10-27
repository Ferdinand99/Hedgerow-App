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
                    Button("Cancel") { dismiss() }
                        .disabled(isWorking)
                }
            }
            // A half-finished connect must not be left running behind a closed sheet.
            .interactiveDismissDisabled(isWorking)
        }
    }

    private func connect() {
        guard let url = parseServiceAddress(address) else {
            errorMessage = String(localized: "Enter a valid address, for example https://vole.example.com")
            return
        }
        errorMessage = nil
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await store.add(url: url, token: token, name: name)
                dismiss()
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

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("New API token", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text(verbatim: "\(connection.name) · \(connection.kind.displayName)")
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
                    Button("Cancel") { dismiss() }
                        .disabled(isWorking)
                }
            }
            .interactiveDismissDisabled(isWorking)
        }
    }

    private func save() {
        errorMessage = nil
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await store.verifyToken(token, for: connection.id)
                try store.replaceToken(connection.id, token: token)
                dismiss()
            } catch {
                errorMessage = userMessage(for: error)
            }
        }
    }
}
