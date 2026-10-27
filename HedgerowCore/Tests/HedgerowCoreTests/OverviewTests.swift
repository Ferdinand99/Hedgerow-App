import Foundation
import Testing
@testable import HedgerowCore

/// A client whose answer the test decides.
private struct StubClient: ServiceClient {
    enum Behaviour: Sendable {
        case summary(ServiceSummary)
        case error(HedgerowError)
        /// Takes far longer than any timeout in these tests (and stops when cancelled).
        case hang
    }

    let behaviour: Behaviour

    func summary() async throws -> ServiceSummary {
        switch behaviour {
        case .summary(let summary): return summary
        case .error(let error): throw error
        case .hang:
            try await Task.sleep(for: .seconds(60))
            throw HedgerowError.unreachable("never")
        }
    }
}

/// Lets a test change what each connection's client does between refreshes.
private final class Script: @unchecked Sendable {
    private let lock = NSLock()
    private var behaviours: [UUID: StubClient.Behaviour] = [:]
    private var tokens: [String?] = []

    func set(_ behaviour: StubClient.Behaviour, for id: UUID) {
        lock.withLock { behaviours[id] = behaviour }
    }

    func client(for connection: Connection, token: String?) -> any ServiceClient {
        lock.withLock {
            tokens.append(token)
            return StubClient(behaviour: behaviours[connection.id] ?? .error(.unreachable("unscripted")))
        }
    }

    var seenTokens: [String?] { lock.withLock { tokens } }
}

/// A vault whose reads fail, like a locked device's Keychain.
private struct UnreadableVault: TokenVault {
    struct Failure: Error {}
    func save(_ token: String, for id: UUID) throws {}
    func token(for id: UUID) throws -> String? { throw Failure() }
    func delete(for id: UUID) throws {}
}

private func summary(_ kind: ServiceKind, _ health: Health, at date: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> ServiceSummary {
    ServiceSummary(
        kind: kind, health: health, headline: SummaryLine("%lld down", .number(0)), details: [], fetchedAt: date
    )
}

@MainActor @Suite struct OverviewModelTests {
    private let file = FileManager.default.temporaryDirectory
        .appendingPathComponent("hedgerow-overview-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("connections.json")

    /// A store pre-filled with one connection per kind and a token for each.
    private func makeFixture(
        script: Script, timeout: Duration = .seconds(5)
    ) throws -> (OverviewModel, ConnectionStore, [Connection]) {
        let connections = [
            Connection(name: "VV", baseURL: URL(string: "https://vole.example.com")!, kind: .vole),
            Connection(name: "KK", baseURL: URL(string: "https://kestrel.example.com")!, kind: .kestrel),
            Connection(name: "Wren", baseURL: URL(string: "https://wren.example.com")!, kind: .wren),
        ]
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try JSONEncoder().encode(connections).write(to: file)
        let vault = InMemoryVault()
        for connection in connections { try vault.save("tok-\(connection.name)", for: connection.id) }
        let store = try ConnectionStore(fileURL: file, vault: vault)
        let model = OverviewModel(store: store, timeout: timeout) { connection, token in
            script.client(for: connection, token: token)
        }
        return (model, store, connections)
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    @Test func loadsAllCardsInParallel() async throws {
        defer { cleanUp() }
        let script = Script()
        let (model, _, connections) = try makeFixture(script: script)
        for connection in connections {
            script.set(.summary(summary(connection.kind, .ok)), for: connection.id)
        }

        await model.refresh()

        #expect(model.cards.count == 3)
        #expect(model.cards.map(\.health) == [.ok, .ok, .ok])
        #expect(model.overallHealth == .ok)
        #expect(Set(script.seenTokens.compactMap { $0 }) == ["tok-VV", "tok-KK", "tok-Wren"])
    }

    @Test func oneServiceDownDoesNotHideTheOthers() async throws {
        defer { cleanUp() }
        let script = Script()
        let (model, _, connections) = try makeFixture(script: script)
        script.set(.summary(summary(.vole, .ok)), for: connections[0].id)
        script.set(.error(.unreachable("offline")), for: connections[1].id)
        script.set(.summary(summary(.wren, .warning)), for: connections[2].id)

        await model.refresh()

        #expect(model.cards[0].phase == .loaded(summary(.vole, .ok)))
        #expect(model.cards[1].phase == .failed(.unreachable, lastGood: nil))
        #expect(model.cards[2].health == .warning)
        #expect(model.overallHealth == .critical)
    }

    @Test func downServiceKeepsItsLastGoodSummary() async throws {
        defer { cleanUp() }
        let script = Script()
        let (model, _, connections) = try makeFixture(script: script)
        let seen = Date(timeIntervalSince1970: 1_700_000_000)
        script.set(.summary(summary(.vole, .ok, at: seen)), for: connections[0].id)
        await model.refresh()

        script.set(.error(.unreachable("offline")), for: connections[0].id)
        await model.refresh()

        #expect(model.cards[0].phase == .failed(.unreachable, lastGood: summary(.vole, .ok, at: seen)))
        #expect(model.cards[0].lastGood?.fetchedAt == seen)

        // And it recovers.
        script.set(.summary(summary(.vole, .ok)), for: connections[0].id)
        await model.refresh()
        #expect(model.cards[0].phase == .loaded(summary(.vole, .ok)))
    }

    @Test func rejectedTokenIsNotAGeneralError() async throws {
        defer { cleanUp() }
        let script = Script()
        let (model, _, connections) = try makeFixture(script: script)
        script.set(.error(.unauthorized), for: connections[0].id)
        script.set(.error(.forbidden), for: connections[1].id)
        script.set(.error(.notHedgerow), for: connections[2].id)

        await model.refresh()

        #expect(model.cards[0].phase == .failed(.tokenRejected, lastGood: nil))
        #expect(model.cards[1].phase == .failed(.tokenRejected, lastGood: nil))
        #expect(model.cards[2].phase == .failed(.notHedgerow, lastGood: nil))
    }

    @Test func slowServiceTimesOutWithoutBlockingTheOthers() async throws {
        defer { cleanUp() }
        let script = Script()
        let (model, _, connections) = try makeFixture(script: script, timeout: .milliseconds(200))
        script.set(.hang, for: connections[0].id)
        script.set(.summary(summary(.kestrel, .ok)), for: connections[1].id)
        script.set(.summary(summary(.wren, .ok)), for: connections[2].id)

        let started = ContinuousClock.now
        await model.refresh()
        let elapsed = ContinuousClock.now - started

        #expect(model.cards[0].phase == .failed(.unreachable, lastGood: nil))
        #expect(model.cards[1].health == .ok)
        #expect(model.cards[2].health == .ok)
        #expect(elapsed < .seconds(5))
    }

    @Test func missingTokenCountsAsRejected() async throws {
        defer { cleanUp() }
        let script = Script()
        let (_, _, connections) = try makeFixture(script: script)
        // Same connections file, but a vault that holds no tokens.
        let bare = try ConnectionStore(fileURL: file, vault: InMemoryVault())
        let model = OverviewModel(store: bare) { connection, token in
            script.client(for: connection, token: token)
        }
        script.set(.summary(summary(.vole, .ok)), for: connections[0].id)

        await model.refresh()

        #expect(model.cards[0].phase == .failed(.tokenRejected, lastGood: nil))
    }

    @Test func unreadableTokenIsNotARejectedToken() async throws {
        defer { cleanUp() }
        let script = Script()
        let (_, _, connections) = try makeFixture(script: script)
        let locked = try ConnectionStore(fileURL: file, vault: UnreadableVault())
        let model = OverviewModel(store: locked) { connection, token in
            script.client(for: connection, token: token)
        }
        for connection in connections {
            script.set(.summary(summary(connection.kind, .ok)), for: connection.id)
        }

        await model.refresh()

        #expect(model.cards.map(\.phase) == Array(repeating: .failed(.tokenUnreadable, lastGood: nil), count: 3))
        #expect(script.seenTokens.isEmpty)
    }

    @Test func refusedRedirectToASignInPageIsNotHedgerow() {
        // The HTTP layer reports a refused redirect as `.notHedgerow`; the card says the same.
        #expect(CardProblem(HedgerowError.notHedgerow) == .notHedgerow)
    }

    @Test func removedConnectionLosesItsCard() async throws {
        defer { cleanUp() }
        let script = Script()
        let (model, store, connections) = try makeFixture(script: script)
        for connection in connections {
            script.set(.summary(summary(connection.kind, .ok)), for: connection.id)
        }
        await model.refresh()

        try store.remove(connections[1].id)
        model.syncCards()

        #expect(model.cards.map(\.id) == [connections[0].id, connections[2].id])
    }

    @Test func overallHealthIsUnknownBeforeAnythingLoaded() throws {
        defer { cleanUp() }
        let (model, _, _) = try makeFixture(script: Script())
        model.syncCards()
        #expect(model.cards.count == 3)
        #expect(model.overallHealth == .unknown)
    }

    // MARK: overall status line

    private func status(_ vole: StubClient.Behaviour, _ kestrel: StubClient.Behaviour, _ wren: StubClient.Behaviour) async throws -> OverallStatus {
        let script = Script()
        let (model, _, connections) = try makeFixture(script: script)
        script.set(vole, for: connections[0].id)
        script.set(kestrel, for: connections[1].id)
        script.set(wren, for: connections[2].id)
        await model.refresh()
        return model.overallStatus
    }

    @Test func overallStatusIsDownOnlyWhenVoleReportsMonitorsDown() async throws {
        defer { cleanUp() }
        let result = try await status(
            .summary(summary(.vole, .critical)), .summary(summary(.kestrel, .ok)), .summary(summary(.wren, .ok)))
        #expect(result == .somethingDown)
    }

    @Test func aCriticalWrenAloneNeedsAttentionButIsNotDown() async throws {
        defer { cleanUp() }
        let result = try await status(
            .summary(summary(.vole, .ok)), .summary(summary(.kestrel, .ok)), .summary(summary(.wren, .critical)))
        #expect(result == .needsAttention)
    }

    @Test func warningsAndUnreachableServicesNeedAttention() async throws {
        defer { cleanUp() }
        let warning = try await status(
            .summary(summary(.vole, .ok)), .summary(summary(.kestrel, .warning)), .summary(summary(.wren, .ok)))
        #expect(warning == .needsAttention)
        let unreachable = try await status(
            .error(.unreachable("offline")), .summary(summary(.kestrel, .ok)), .summary(summary(.wren, .ok)))
        #expect(unreachable == .needsAttention)
    }

    @Test func overallStatusIsOkWhenAllIsWellAndUnknownBeforeLoading() async throws {
        defer { cleanUp() }
        let ok = try await status(
            .summary(summary(.vole, .ok)), .summary(summary(.kestrel, .ok)), .summary(summary(.wren, .ok)))
        #expect(ok == .ok)
        let (model, _, _) = try makeFixture(script: Script())
        #expect(model.overallStatus == .unknown)
    }
}
