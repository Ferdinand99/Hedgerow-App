import HedgerowCore
import SwiftUI

struct ConnectionsView: View {
    let store: ConnectionStore
    let model: OverviewModel

    @State private var showingAdd = false
    @State private var replacingTokenFor: Connection?
    @State private var removalError: String?

    var body: some View {
        List {
            ForEach(store.connections) { connection in
                VStack(alignment: .leading, spacing: 2) {
                    Text(connection.name)
                    Text(verbatim: "\(connection.kind.displayName) · \(connection.baseURL.absoluteString)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button("Remove", role: .destructive) { remove(connection) }
                    Button("Replace token") { replacingTokenFor = connection }
                        .tint(.blue)
                }
            }
        }
        .overlay {
            if store.connections.isEmpty {
                ContentUnavailableView {
                    Label("No connections", systemImage: "link")
                } actions: {
                    Button("Add a service") { showingAdd = true }
                }
            }
        }
        .navigationTitle("Connections")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingAdd = true } label: {
                    Label("Add a service", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAdd) {
            AddConnectionView(store: store)
        }
        .sheet(item: $replacingTokenFor) { connection in
            ReplaceTokenView(store: store, connection: connection)
        }
        .onChange(of: replacingTokenFor) { _, connection in
            // After a token was replaced, the Overview should show how the new one works.
            if connection == nil { Task { await model.refresh() } }
        }
        .alert(
            "Couldn't remove the connection.",
            isPresented: Binding(get: { removalError != nil }, set: { if !$0 { removalError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(removalError ?? "")
        }
    }

    /// Removes the token from the Keychain and the connection from the list.
    private func remove(_ connection: Connection) {
        do {
            try store.remove(connection.id)
            model.syncCards()
        } catch {
            removalError = userMessage(for: error)
        }
    }
}
