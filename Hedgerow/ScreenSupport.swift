import HedgerowCore
import SwiftUI

// What the tabs and detail screens have in common: how their models load, when a screen refreshes,
// and how a client is made from a saved connection.

// MARK: - Clients

/// A Vigilant Vole client for a connection, or the problem that stops one: no token readable, or
/// none saved (the same to the user as a token that does not work).
@MainActor
func voleClient(for connection: Connection, store: ConnectionStore) -> Result<VoleClient, CardProblem> {
    loadedToken(for: connection, in: store).map {
        VoleClient(baseURL: connection.baseURL, http: HedgerowHTTP(token: $0))
    }
}

/// A Keen Kestrel client for a connection, or the problem that stops one (see `voleClient`).
@MainActor
func kestrelClient(for connection: Connection, store: ConnectionStore) -> Result<KestrelClient, CardProblem> {
    loadedToken(for: connection, in: store).map {
        KestrelClient(baseURL: connection.baseURL, http: HedgerowHTTP(token: $0))
    }
}

/// A Wise Wren client for a connection, or the problem that stops one (see `voleClient`).
@MainActor
func wrenClient(for connection: Connection, store: ConnectionStore) -> Result<WrenClient, CardProblem> {
    loadedToken(for: connection, in: store).map {
        WrenClient(baseURL: connection.baseURL, http: HedgerowHTTP(token: $0))
    }
}

// MARK: - Model

/// The model of a screen that loads from one server. It brings the one refresh policy:
/// `loadIfStale()` when the screen appears, `load()` for pull to refresh, a reload button and the app
/// becoming active (see `refreshPolicy`). The state of the last load is the `loader`'s.
@MainActor
protocol ScreenModel: AnyObject, Sendable {
    var loader: LoadTracker { get }
    /// Fetches and applies the data. Throws a `CardProblem` (or any error) when that fails; asks the
    /// `ticket` whether a newer load has started before it touches anything on screen.
    func fetch(_ ticket: LoadTracker.Ticket) async throws
}

extension ScreenModel {
    /// Always loads.
    func load() async { await loader.load(fetch) }
    /// Loads when nothing has loaded yet, the last load failed or the data is 30 seconds old.
    func loadIfStale() async { await loader.loadIfStale(fetch) }

    /// True until the first load has ended, and while a load runs.
    var isLoading: Bool { loader.isLoading }
    /// Why the last load failed; what was loaded before stays on screen next to it.
    var problem: CardProblem? { loader.problem }
    var lastLoaded: Date? { loader.lastLoaded }
}

// MARK: - Refresh policy

private struct RefreshPolicy<Model: ScreenModel>: ViewModifier {
    let model: Model
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            // Appearing: a tab switch or coming back from a pushed view. Fresh data is left alone.
            .task { await model.loadIfStale() }
            // Coming back to the app always loads.
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await model.load() } }
            }
    }
}

extension View {
    /// The refresh policy of every tab and detail screen: load when the screen appears and its data
    /// is missing or stale, load again whenever the app becomes active. Pull to refresh and reload
    /// buttons call `model.load()` themselves.
    func refreshPolicy(_ model: some ScreenModel) -> some View {
        modifier(RefreshPolicy(model: model))
    }
}

// MARK: - Empty state

/// What a list screen shows while it has nothing to list: why it failed, that it is loading, or
/// (when it did load) `empty`.
struct ServiceEmptyState<Empty: View>: View {
    let model: any ScreenModel
    let replaceToken: () -> Void
    @ViewBuilder let empty: Empty

    var body: some View {
        if let problem = model.problem {
            ServiceProblemView(problem: problem, lastSeen: model.lastLoaded, replaceToken: replaceToken)
        } else if model.isLoading {
            ServiceLoadingView()
        } else {
            empty
        }
    }
}
