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

    var body: some View {
        TabView(selection: $selection) {
            Tab("Overview", systemImage: "square.grid.2x2", value: AppTab.overview) {
                NavigationStack {
                    OverviewView(store: store, model: model, onOpen: showService)
                }
            }
            Tab("Monitors", systemImage: "waveform.path.ecg", value: AppTab.monitors) {
                ServiceTab(kind: .vole, title: "Monitors", store: store, model: model, picks: picks) { context in
                    ServiceTabPlaceholder(context: context, model: model)
                }
            }
            Tab("Issues", systemImage: "ladybug", value: AppTab.issues) {
                ServiceTab(kind: .kestrel, title: "Issues", store: store, model: model, picks: picks) { context in
                    ServiceTabPlaceholder(context: context, model: model)
                }
            }
            Tab("Updates", systemImage: "arrow.triangle.2.circlepath", value: AppTab.updates) {
                ServiceTab(kind: .wren, title: "Updates", store: store, model: model, picks: picks) { context in
                    ServiceTabPlaceholder(context: context, model: model)
                }
            }
            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                NavigationStack {
                    ConnectionsView(store: store, model: model)
                }
            }
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
    @ViewBuilder let content: (ServiceContext) -> Content

    @State private var showingAdd = false
    @State private var replacingTokenFor: Connection?
    /// Bumped when the token sheet closes, so the screen loads again with the new token.
    @State private var reloads = 0

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
        .sheet(isPresented: $showingAdd) {
            AddConnectionView(store: store)
        }
        .sheet(item: $replacingTokenFor) { connection in
            ReplaceTokenView(store: store, connection: connection)
        }
        .onChange(of: replacingTokenFor) { _, new in
            if new == nil {
                reloads += 1
                Task { await model.refresh() }
            }
        }
    }
}
