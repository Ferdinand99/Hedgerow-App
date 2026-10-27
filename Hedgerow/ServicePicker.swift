import HedgerowCore
import Observation
import SwiftUI

/// Which connection each per-service tab shows. Wraps `ServiceSelection` (which remembers the
/// choice in `UserDefaults`, ids only) so SwiftUI redraws the tabs when the choice changes.
@MainActor @Observable
final class ServicePicks {
    @ObservationIgnored private let selection: ServiceSelection
    /// Read by `selected`, bumped by `select`: the change SwiftUI observes.
    private var revision = 0

    init(selection: ServiceSelection = ServiceSelection()) {
        self.selection = selection
    }

    func selected(for kind: ServiceKind, among connections: [Connection]) -> Connection? {
        _ = revision
        return selection.selected(for: kind, among: connections)
    }

    func select(_ connection: Connection) {
        selection.select(connection)
        revision += 1
    }
}

/// The menu at the top of a service tab, shown only when there is more than one connection of
/// that product. Choosing one swaps the whole tab to that server, so data from two servers is
/// never shown together.
struct ServicePicker: View {
    let connections: [Connection]
    let selected: Connection
    let choose: (Connection) -> Void

    var body: some View {
        Menu {
            Picker("Choose connection", selection: Binding(
                get: { selected.id },
                set: { id in
                    if let connection = connections.first(where: { $0.id == id }) { choose(connection) }
                }
            )) {
                ForEach(connections) { connection in
                    // The host tells two connections with the same name apart.
                    Text(verbatim: "\(connection.displayName) · \(connection.baseURL.host() ?? "")")
                        .tag(connection.id)
                }
            }
        } label: {
            Label {
                Text(verbatim: selected.displayName)
            } icon: {
                Image(systemName: "chevron.up.chevron.down")
            }
            .labelStyle(.titleAndIcon)
        }
        .accessibilityLabel("Choose connection")
        .accessibilityValue(selected.displayName)
    }
}
