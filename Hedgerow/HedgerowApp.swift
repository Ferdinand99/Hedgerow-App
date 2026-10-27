import HedgerowCore
import SwiftUI

@main
struct HedgerowApp: App {
    @State private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(app: app)
        }
    }
}

struct RootView: View {
    let app: AppModel

    var body: some View {
        switch app.state {
        case .ready(let store, let model):
            RootTabView(store: store, model: model)
        case .storageDamaged:
            StorageDamagedView(app: app)
        }
    }
}

/// Shown instead of the app when the saved connections can't be read. Starting with an empty
/// list would hide the problem and the next save would overwrite the damaged file.
struct StorageDamagedView: View {
    let app: AppModel
    @State private var confirmingReset = false

    var body: some View {
        ContentUnavailableView {
            Label("Your saved connections can't be read", systemImage: "exclamationmark.triangle")
        } description: {
            Text("The file with your connections is damaged. You can reset it and add the services again. Tokens saved in the Keychain are removed too.")
        } actions: {
            Button("Reset connections", role: .destructive) {
                confirmingReset = true
            }
            .buttonStyle(.borderedProminent)
        }
        .confirmationDialog("Reset all connections?", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { app.resetConnections() }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Couldn't reset the connections.", isPresented: Binding(
            get: { app.resetFailed }, set: { app.resetFailed = $0 }
        )) {
            Button("OK", role: .cancel) {}
        }
    }
}
