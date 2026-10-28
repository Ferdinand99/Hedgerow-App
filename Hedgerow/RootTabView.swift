import HedgerowCore
import SwiftUI

enum AppTab: Hashable {
    case overview, monitors, issues, updates, settings

    /// The tab that shows a product.
    init(kind: ServiceKind) {
        switch kind {
        case .vole: self = .monitors
        case .kestrel: self = .issues
        case .wren: self = .updates
        }
    }
}

/// The bottom tab bar. Each tab has its own `NavigationStack`.
struct RootTabView: View {
    let store: ConnectionStore
    let model: OverviewModel

    @State var selection: AppTab = .overview
    @State private var picks = ServicePicks()
    @Environment(PushController.self) private var push
    /// Bumped by a tap on a notification: the service tabs start over at their first screen.
    @State private var stackResets = 0

    var body: some View {
        TabView(selection: $selection) {
            Tab("Overview", systemImage: "square.grid.2x2", value: AppTab.overview) {
                NavigationStack {
                    OverviewView(store: store, model: model, onOpen: showService)
                }
            }
            Tab("Monitors", systemImage: "waveform.path.ecg", value: AppTab.monitors) {
                ServiceTab(kind: .vole, title: "Monitors", store: store, model: model, picks: picks, resets: stackResets) { context in
                    MonitorsView(context: context, store: store)
                }
            }
            Tab("Issues", systemImage: "ladybug", value: AppTab.issues) {
                ServiceTab(kind: .kestrel, title: "Issues", store: store, model: model, picks: picks, resets: stackResets) { context in
                    IssuesView(context: context, store: store)
                }
            }
            Tab("Updates", systemImage: "arrow.triangle.2.circlepath", value: AppTab.updates) {
                ServiceTab(kind: .wren, title: "Updates", store: store, model: model, picks: picks, resets: stackResets) { context in
                    UpdatesView(context: context, store: store)
                }
            }
            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                NavigationStack {
                    ConnectionsView(store: store, model: model)
                }
            }
        }
        // A tap on a notification: the tab of that product, with that connection selected. Also
        // when the tap is what started the app (the request is waiting here).
        .onChange(of: push.openRequest, initial: true) { _, request in
            guard let request else { return }
            // Only one of the app's own connections can be shown.
            if let connection = store.connections.first(where: { $0.id == request.connectionId }) {
                // Back to the first screen of the tab: the notification is about this connection, not
                // about whatever screen was open in that tab before.
                stackResets += 1
                showService(connection)
            }
            push.clearOpenRequest()
        }
        // A connection was added or removed: its handle follows.
        .onChange(of: store.connections.map(\.id)) {
            push.syncConnections()
        }
    }

    /// A tap on an Overview card: the tab of that product, with that connection selected.
    private func showService(_ connection: Connection) {
        picks.select(connection)
        selection = AppTab(kind: connection.kind)
    }
}

/// What a service tab hands to its screen: the connection to show and how to replace its token.
struct ServiceContext {
    let connection: Connection
    let replaceToken: () -> Void
}

/// The frame of Monitors, Issues and Updates: the selected connection of one product, the picker
/// when there are several, and the shared "not connected" state when there are none.
/// When the selected connection goes away, the next one is shown, or the not-connected state.
struct ServiceTab<Content: View>: View {
    let kind: ServiceKind
    let title: LocalizedStringKey
    let store: ConnectionStore
    let model: OverviewModel
    let picks: ServicePicks
    /// Changing it gives the tab's `NavigationStack` a new identity, which pops it to its root.
    let resets: Int
    @ViewBuilder let content: (ServiceContext) -> Content

    @State private var showingAdd = false
    @State private var replacingTokenFor: Connection?
    /// Bumped when the token sheet closes with a different token, so the screen loads again with it.
    @State private var reloads = 0
    /// The store's `tokenChanges` when the sheet opened, to tell "Cancel" from "Save" when it closes.
    @State private var tokenChangesWhenSheetOpened = 0

    var body: some View {
        let options = connections(of: kind, in: store)
        let current = picks.selected(for: kind, among: options)
        NavigationStack {
            Group {
                if let current {
                    content(ServiceContext(connection: current, replaceToken: { replacingTokenFor = current }))
                        // A new identity per connection: nothing from one server lingers on screen
                        // (or in the screen's state) after switching to another.
                        .id("\(current.id.uuidString)-\(reloads)")
                } else {
                    ServiceEmptyView(kind: kind) { showingAdd = true }
                }
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if options.count > 1, let current {
                        ServicePicker(connections: options, selected: current) { picks.select($0) }
                    }
                }
            }
        }
        .id(resets)
        .sheet(isPresented: $showingAdd) {
            AddConnectionView(store: store)
        }
        .sheet(item: $replacingTokenFor) { connection in
            ReplaceTokenView(store: store, connection: connection)
        }
        .onChange(of: replacingTokenFor) { _, new in
            if new != nil {
                tokenChangesWhenSheetOpened = store.tokenChanges
            } else if store.tokenChanges != tokenChangesWhenSheetOpened {
                // Only a token that was saved (or removed) reloads; cancelling the sheet changes nothing.
                reloads += 1
                Task { await model.refresh() }
            }
        }
    }
}
