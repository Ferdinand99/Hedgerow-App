import Foundation
import Observation

// What every tab and detail screen shares when it loads from a server: how a load is tracked, when
// the data counts as stale, where the token comes from, and how a side request may fail without
// failing the screen.

/// Tracks the loads of one screen: whether one runs, why the last one failed, when one last
/// succeeded, and which of several overlapping loads is the current one.
///
/// The refresh policy lives here, once, for every screen:
/// - `loadIfStale` is for a screen appearing (tab switch, pop back from a pushed view): it loads only
///   when there is no data yet, the last load failed, or the data is older than `staleAfter`;
/// - `load` always loads; it is for pull to refresh, a reload button and the app becoming active.
///
/// A newer load makes an older one stop touching the screen: the older one's `work` can ask its
/// `Ticket` whether it is still current before it applies anything.
@MainActor @Observable
public final class LoadTracker {
    /// Data younger than this is not loaded again when a screen merely appears.
    public static let staleAfter: TimeInterval = 30

    /// True until the first load has ended, and while a load runs.
    public private(set) var isLoading = true
    /// Why the last load failed; what was loaded before stays on screen next to it.
    public private(set) var problem: CardProblem?
    /// When a load last succeeded. `nil` while nothing has loaded yet.
    public private(set) var lastLoaded: Date?

    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let clock: @Sendable () -> Date

    public init(clock: @escaping @Sendable () -> Date = { Date() }) {
        self.clock = clock
    }

    /// Names one load. `isCurrent` turns false as soon as a newer load starts.
    public struct Ticket: Sendable {
        fileprivate let tracker: LoadTracker
        fileprivate let generation: Int

        @MainActor public var isCurrent: Bool { tracker.generation == generation }
    }

    /// The ticket of the latest load (or of the first one to come), for follow-up work that must not
    /// outlive a reload, like the next page of a list.
    public var ticket: Ticket { Ticket(tracker: self, generation: generation) }

    /// Whether a screen that appears now should load: nothing loaded yet (including a first load
    /// that failed), or the data is `staleAfter` old. A failed refresh over data the screen still
    /// shows waits for the same age, so coming back to a screen doesn't throw away what was loaded
    /// (a scrolled list, say); pull to refresh retries at once.
    public var isStale: Bool {
        guard let lastLoaded else { return true }
        let age = clock().timeIntervalSince(lastLoaded)
        return age < 0 || age >= Self.staleAfter
    }

    /// For a screen appearing: loads only if the data is stale (see `isStale`).
    public func loadIfStale(_ work: @MainActor (Ticket) async throws -> Void) async {
        guard isStale else { return }
        await load(work)
    }

    /// Always loads. `work` fetches and applies the result; it throws a `CardProblem` (or any error,
    /// which becomes one) for a failure. A failure leaves `lastLoaded` as it was, and a cancelled or
    /// superseded load changes nothing.
    public func load(_ work: @MainActor (Ticket) async throws -> Void) async {
        generation += 1
        let mine = generation
        isLoading = true
        defer { if mine == generation { isLoading = false } }

        do {
            try await work(Ticket(tracker: self, generation: mine))
            guard mine == generation else { return }
            problem = nil
            lastLoaded = clock()
        } catch is CancellationError {
            return
        } catch {
            guard mine == generation, !Task.isCancelled else { return }
            problem = (error as? CardProblem) ?? CardProblem(error)
        }
    }
}

/// The token saved for a connection, or the problem that stops a client from being built: no token
/// readable (the Keychain failed), or none saved (the same to the user as a token that does not work).
@MainActor
public func loadedToken(for connection: Connection, in store: ConnectionStore) -> Result<String, CardProblem> {
    let token: String?
    do {
        token = try store.token(for: connection.id)
    } catch {
        return .failure(.tokenUnreadable)
    }
    guard let token else { return .failure(.tokenRejected) }
    return .success(token)
}

/// For data that only decorates a screen (server names, project groups): any failure gives
/// `fallback` instead, so the screen is not lost with it. Cancellation still propagates.
public func orFallback<Value: Sendable>(
    _ fallback: Value, _ work: () async throws -> Value
) async throws -> Value {
    do {
        return try await work()
    } catch is CancellationError {
        throw CancellationError()
    } catch {
        try Task.checkCancellation()
        return fallback
    }
}
