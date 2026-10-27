import Foundation

/// The saved connections of one product, in the order they were added.
@MainActor
public func connections(of kind: ServiceKind, in store: ConnectionStore) -> [Connection] {
    store.connections.filter { $0.kind == kind }
}

/// Which connection a per-service tab (Monitors, Issues, Updates) shows when there is more than
/// one of the same product. Remembers the choice per product in `UserDefaults`; only the
/// connection id is stored, never a token, an address or a name.
public struct ServiceSelection {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func key(for kind: ServiceKind) -> String {
        "selectedConnection.\(kind.rawValue)"
    }

    /// The remembered connection if it is still among `connections` (and of this `kind`),
    /// otherwise the first connection of this `kind`, otherwise `nil`. A removed connection
    /// therefore falls back to the first remaining one without anything to clean up.
    public func selected(for kind: ServiceKind, among connections: [Connection]) -> Connection? {
        let candidates = connections.filter { $0.kind == kind }
        if let text = defaults.string(forKey: Self.key(for: kind)),
           let id = UUID(uuidString: text),
           let remembered = candidates.first(where: { $0.id == id }) {
            return remembered
        }
        return candidates.first
    }

    /// Remembers `connection` as the one to show for its product.
    public func select(_ connection: Connection) {
        defaults.set(connection.id.uuidString, forKey: Self.key(for: connection.kind))
    }
}
