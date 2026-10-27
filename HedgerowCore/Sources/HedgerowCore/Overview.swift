import Foundation
import Observation

/// Why a card has no fresh summary. The app turns each case into a message; none of them
/// affects any other card.
public enum CardProblem: Error, Sendable, Equatable {
    /// No answer in time, the connection failed or a gateway answered 5xx: "Can't reach it".
    case unreachable
    /// 401/403, or no token in the Keychain: "The token doesn't work", with a way to replace it.
    case tokenRejected
    /// The address now answers with something that is not (this) Hedgerow product, for example
    /// a gateway's sign-in page it redirects to.
    case notHedgerow
    /// The token could not be read from the Keychain (device locked, Keychain error). Not the
    /// same as a token the server refuses.
    case tokenUnreadable
    /// An answer the app cannot read (wrong shape, too large, unexpected status).
    case unexpectedAnswer
    /// The saved address is not allowed (plain http to a public host).
    case insecure

    init(_ error: any Error) {
        switch error as? HedgerowError {
        case .unauthorized?, .forbidden?: self = .tokenRejected
        case .notHedgerow?: self = .notHedgerow
        case .insecureURL?: self = .insecure
        case .unreachable?: self = .unreachable
        case .badResponse(let status)? where status >= 500: self = .unreachable
        case .badResponse?, .tooLarge?, .unexpectedResponse?: self = .unexpectedAnswer
        case nil: self = .unexpectedAnswer
        }
    }
}

/// The line above the cards. "Something is down" is reserved for Vigilant Vole reporting monitors
/// down; any other critical or warning state (a failed Wise Wren update run, an unreachable
/// service) is "needs attention", so the line never claims more than it knows.
public enum OverallStatus: Sendable, Equatable {
    case unknown
    case ok
    case needsAttention
    case somethingDown
}

/// One card on the Overview: a saved connection and what is known about it.
public struct ServiceCard: Identifiable, Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        /// Nothing fetched yet.
        case loading
        case loaded(ServiceSummary)
        /// The last fetch failed. `lastGood` is the previous good summary, if there was one.
        case failed(CardProblem, lastGood: ServiceSummary?)
    }

    public let connection: Connection
    public fileprivate(set) var phase: Phase
    /// The last summary that was fetched successfully, kept in memory while the service is down.
    public fileprivate(set) var lastGood: ServiceSummary?

    public var id: UUID { connection.id }

    init(connection: Connection, phase: Phase, lastGood: ServiceSummary?) {
        self.connection = connection
        self.phase = phase
        self.lastGood = lastGood
    }

    /// How the card should be coloured.
    public var health: Health {
        switch phase {
        case .loading: .unknown
        case .loaded(let summary): summary.health
        case .failed(.unreachable, _), .failed(.unexpectedAnswer, _): .critical
        case .failed: .warning
        }
    }
}

/// Fetches every connection's summary in parallel and keeps one card per connection.
/// One slow or broken service never delays or hides another.
@MainActor @Observable
public final class OverviewModel {
    /// Longest a single service may take before its card says it can't be reached.
    public static let defaultTimeout: Duration = .seconds(10)

    public private(set) var cards: [ServiceCard] = []
    public private(set) var isRefreshing = false

    @ObservationIgnored private let store: ConnectionStore
    @ObservationIgnored private let clientFactory: @Sendable (Connection, String?) -> any ServiceClient
    @ObservationIgnored private let timeout: Duration
    @ObservationIgnored private var refreshRequestedWhileBusy = false

    public init(
        store: ConnectionStore,
        timeout: Duration = OverviewModel.defaultTimeout,
        clientFactory: @escaping @Sendable (Connection, String?) -> any ServiceClient = {
            makeClient(for: $0, token: $1)
        }
    ) {
        self.store = store
        self.timeout = timeout
        self.clientFactory = clientFactory
        syncCards()
    }

    /// Red if anything is down, yellow if anything needs attention, green when all is well.
    public var overallHealth: Health {
        let loaded = cards.filter { $0.phase != .loading }
        guard !loaded.isEmpty else { return .unknown }
        let all = loaded.map(\.health)
        if all.contains(.critical) { return .critical }
        if all.contains(.warning) { return .warning }
        if all.allSatisfy({ $0 == .unknown }) { return .unknown }
        return .ok
    }

    /// What the line above the cards says: "down" only when a Vigilant Vole card reports monitors
    /// down, "needs attention" for any other critical or warning card, "ok" when all is well.
    public var overallStatus: OverallStatus {
        let loaded = cards.filter { $0.phase != .loading }
        guard !loaded.isEmpty else { return .unknown }
        let voleReportsDown = loaded.contains { card in
            if case .loaded(let summary) = card.phase {
                return card.connection.kind == .vole && summary.health == .critical
            }
            return false
        }
        if voleReportsDown { return .somethingDown }
        switch overallHealth {
        case .critical, .warning: return .needsAttention
        case .ok: return .ok
        case .unknown: return .unknown
        }
    }

    /// Makes `cards` match the saved connections (new ones start as "loading", removed ones go,
    /// the last good summaries stay) without touching the network.
    public func syncCards() {
        let existing = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0) })
        cards = store.connections.map { connection in
            if let card = existing[connection.id] {
                // Name and address are the connection's own; take the saved ones.
                return ServiceCard(connection: connection, phase: card.phase, lastGood: card.lastGood)
            }
            return ServiceCard(connection: connection, phase: .loading, lastGood: nil)
        }
    }

    /// Fetches all summaries in parallel, each with its own timeout. Cards update as their
    /// answers arrive. Cancelling the caller (pull to refresh being torn down) does not
    /// abandon a half-finished refresh.
    public func refresh() async {
        await Task { await self.performRefresh() }.value
    }

    private func performRefresh() async {
        syncCards()
        // A refresh asked for while one is running (a connection was added meanwhile) runs
        // right after it, so nothing is skipped and nothing runs twice at once.
        guard !isRefreshing else {
            refreshRequestedWhileBusy = true
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        repeat {
            refreshRequestedWhileBusy = false
            await fetchAll()
            if refreshRequestedWhileBusy { syncCards() }
        } while refreshRequestedWhileBusy
    }

    private func fetchAll() async {
        var jobs: [Job] = []
        for connection in store.connections {
            let token: String?
            do {
                token = try store.token(for: connection.id)
            } catch {
                // The Keychain could not be read (e.g. the device is locked): not a rejected token.
                apply(.failure(.tokenUnreadable), to: connection.id)
                continue
            }
            // No token in the Keychain is the same to the user as a token that doesn't work.
            guard let token else {
                apply(.failure(.tokenRejected), to: connection.id)
                continue
            }
            jobs.append(Job(connection: connection, client: clientFactory(connection, token)))
        }

        let timeout = self.timeout
        await withTaskGroup(of: (UUID, Result<ServiceSummary, CardProblem>?).self) { group in
            for job in jobs {
                group.addTask {
                    (job.connection.id, await Self.fetch(job.client, timeout: timeout))
                }
            }
            for await (id, result) in group {
                if let result { apply(result, to: id) }
            }
        }
    }

    private struct Job: Sendable {
        let connection: Connection
        let client: any ServiceClient
    }

    /// `nil` when the work itself was cancelled: the card keeps what it had.
    private nonisolated static func fetch(
        _ client: any ServiceClient, timeout: Duration
    ) async -> Result<ServiceSummary, CardProblem>? {
        await withTaskGroup(of: Result<ServiceSummary, CardProblem>?.self) { group in
            group.addTask {
                do {
                    return .success(try await client.summary())
                } catch is CancellationError {
                    return nil
                } catch {
                    return .failure(CardProblem(error))
                }
            }
            group.addTask {
                do {
                    try await Task.sleep(for: timeout)
                    return .failure(.unreachable)
                } catch {
                    return nil
                }
            }
            // The first child to finish with a verdict wins; the other is cancelled.
            var outcome: Result<ServiceSummary, CardProblem>?
            for await result in group {
                if let result {
                    outcome = result
                    group.cancelAll()
                    break
                }
                if Task.isCancelled { break }
            }
            group.cancelAll()
            return outcome
        }
    }

    private func apply(_ result: Result<ServiceSummary, CardProblem>, to id: UUID) {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
        switch result {
        case .success(let summary):
            cards[index].lastGood = summary
            cards[index].phase = .loaded(summary)
        case .failure(let problem):
            cards[index].phase = .failed(problem, lastGood: cards[index].lastGood)
        }
    }
}
