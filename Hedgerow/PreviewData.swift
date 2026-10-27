#if DEBUG
import HedgerowCore
import SwiftUI

/// Sample data for SwiftUI previews: an in-memory vault, a throwaway connections file and
/// clients that answer with canned summaries. Nothing here touches the network or the Keychain.
private struct SampleClient: ServiceClient {
    let outcome: Result<ServiceSummary, HedgerowError>

    func summary() async throws -> ServiceSummary {
        try outcome.get()
    }
}

@MainActor
enum PreviewData {
    static let vole = Connection(name: "Home Vole", baseURL: URL(string: "https://vole.example.com")!, kind: .vole)
    static let kestrel = Connection(name: "Home Kestrel", baseURL: URL(string: "http://10.0.3.26:3002")!, kind: .kestrel)
    static let wren = Connection(name: "Tower Wren", baseURL: URL(string: "https://wren.example.com")!, kind: .wren)

    static func summary(_ kind: ServiceKind, _ health: Health, _ headline: SummaryLine, _ details: [SummaryLine]) -> ServiceSummary {
        ServiceSummary(kind: kind, health: health, headline: headline, details: details, fetchedAt: Date().addingTimeInterval(-90))
    }

    /// A store with `connections` and a model whose clients answer from `outcomes` (by connection id).
    static func make(
        _ connections: [Connection], outcomes: [UUID: Result<ServiceSummary, HedgerowError>] = [:]
    ) -> (ConnectionStore, OverviewModel) {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("hedgerow-preview-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("connections.json")
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // swiftlint:disable:next force_try
        try! JSONEncoder().encode(connections).write(to: file)
        let vault = InMemoryVault()
        for connection in connections { try? vault.save("preview-token", for: connection.id) }
        // swiftlint:disable:next force_try
        let store = try! ConnectionStore(fileURL: file, vault: vault)
        let model = OverviewModel(store: store) { connection, _ in
            SampleClient(outcome: outcomes[connection.id] ?? .failure(.unreachable("preview")))
        }
        return (store, model)
    }

    /// One service down, one fine, one with a token that doesn't work.
    static func mixed() -> (ConnectionStore, OverviewModel) {
        make([vole, kestrel, wren], outcomes: [
            vole.id: .success(summary(
                .vole, .critical, SummaryLine("%lld down", .number(2)),
                [SummaryLine("%@ is down", .text("Router")), SummaryLine("%lld up", .number(38))]
            )),
            kestrel.id: .success(summary(
                .kestrel, .ok, SummaryLine("No open issues"), []
            )),
            wren.id: .failure(.unauthorized),
        ])
    }
}

#Preview("Overview, mixed") {
    let (store, model) = PreviewData.mixed()
    return NavigationStack { OverviewView(store: store, model: model) }
}

#Preview("Overview, empty") {
    let (store, model) = PreviewData.make([])
    return NavigationStack { OverviewView(store: store, model: model) }
}

#Preview("Add") {
    let (store, _) = PreviewData.make([])
    return AddConnectionView(store: store)
}

#Preview("Connections") {
    let (store, model) = PreviewData.mixed()
    return NavigationStack { ConnectionsView(store: store, model: model) }
}
#endif
