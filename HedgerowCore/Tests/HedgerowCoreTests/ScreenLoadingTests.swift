import Foundation
import Testing
@testable import HedgerowCore

/// A clock the tests move by hand.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)

    var now: Date { lock.withLock { current } }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}

private struct Boom: Error {}

@MainActor private final class Counter {
    var loads = 0
}

@MainActor @Suite struct LoadTrackerTests {
    private func tracker(_ clock: TestClock) -> LoadTracker {
        LoadTracker(clock: { clock.now })
    }

    @Test func startsAsLoadingWithNothingLoaded() {
        let tracker = tracker(TestClock())
        #expect(tracker.isLoading)
        #expect(tracker.problem == nil)
        #expect(tracker.lastLoaded == nil)
        #expect(tracker.isStale)
    }

    @Test func aSuccessfulLoadRecordsWhenAndEndsLoading() async {
        let clock = TestClock()
        let tracker = tracker(clock)
        await tracker.load { _ in }
        #expect(!tracker.isLoading)
        #expect(tracker.problem == nil)
        #expect(tracker.lastLoaded == clock.now)
    }

    @Test func appearingLoadsWhenThereIsNoDataYet() async {
        let counter = Counter()
        let tracker = tracker(TestClock())
        await tracker.loadIfStale { _ in counter.loads += 1 }
        #expect(counter.loads == 1)
    }

    @Test func appearingAgainWithFreshDataDoesNotLoad() async {
        let clock = TestClock()
        let counter = Counter()
        let tracker = tracker(clock)
        await tracker.loadIfStale { _ in counter.loads += 1 }
        clock.advance(LoadTracker.staleAfter - 1)
        await tracker.loadIfStale { _ in counter.loads += 1 }
        #expect(counter.loads == 1)
        #expect(!tracker.isStale)
    }

    @Test func appearingAgainWithOldDataLoads() async {
        let clock = TestClock()
        let counter = Counter()
        let tracker = tracker(clock)
        await tracker.loadIfStale { _ in counter.loads += 1 }
        clock.advance(LoadTracker.staleAfter)
        #expect(tracker.isStale)
        await tracker.loadIfStale { _ in counter.loads += 1 }
        #expect(counter.loads == 2)
        #expect(tracker.lastLoaded == clock.now)
    }

    @Test func aForcedLoadLoadsEvenWithFreshData() async {
        let counter = Counter()
        let tracker = tracker(TestClock())
        await tracker.load { _ in counter.loads += 1 }
        await tracker.load { _ in counter.loads += 1 }
        #expect(counter.loads == 2)
    }

    @Test func aClockThatWentBackCountsAsStale() async {
        let clock = TestClock()
        let tracker = tracker(clock)
        await tracker.load { _ in }
        clock.advance(-120)
        #expect(tracker.isStale)
    }

    @Test func aFailureKeepsTheLastGoodTimeAndIsRetriedWhenAppearing() async {
        let clock = TestClock()
        let counter = Counter()
        let tracker = tracker(clock)
        await tracker.load { _ in }
        let good = tracker.lastLoaded
        clock.advance(5)

        await tracker.load { _ in throw HedgerowError.unreachable("down") }
        #expect(tracker.problem == .unreachable)
        #expect(tracker.lastLoaded == good)
        #expect(!tracker.isLoading)

        // Not old yet, but the screen shows a problem: appearing tries again.
        await tracker.loadIfStale { _ in counter.loads += 1 }
        #expect(counter.loads == 1)
        #expect(tracker.problem == nil)
    }

    @Test func aProblemThrownByTheWorkIsKeptAsIs() async {
        let tracker = tracker(TestClock())
        await tracker.load { _ in throw CardProblem.tokenRejected }
        #expect(tracker.problem == .tokenRejected)
        await tracker.load { _ in throw CardProblem.tokenUnreadable }
        #expect(tracker.problem == .tokenUnreadable)
    }

    @Test func otherErrorsBecomeTheMatchingProblem() async {
        let tracker = tracker(TestClock())
        await tracker.load { _ in throw HedgerowError.unauthorized }
        #expect(tracker.problem == .tokenRejected)
        await tracker.load { _ in throw Boom() }
        #expect(tracker.problem == .unexpectedAnswer)
    }

    @Test func aCancelledLoadChangesNothing() async {
        let tracker = tracker(TestClock())
        await tracker.load { _ in throw HedgerowError.unreachable("down") }
        #expect(tracker.problem == .unreachable)

        await tracker.load { _ in throw CancellationError() }
        #expect(tracker.problem == .unreachable)
        #expect(!tracker.isLoading)
    }

    @Test func aLoadThatFailsBecauseTheTaskWasCancelledIsNotAProblem() async {
        let tracker = tracker(TestClock())
        await tracker.load { _ in }
        let task = Task { @MainActor in
            await tracker.load { _ in
                // The transport's own error when the task is cancelled under it.
                withUnsafeCurrentTask { $0?.cancel() }
                throw HedgerowError.unreachable("down")
            }
        }
        await task.value
        #expect(tracker.problem == nil)
    }

    @Test func aTicketIsCurrentUntilANewerLoadStarts() async {
        let tracker = tracker(TestClock())
        var first: LoadTracker.Ticket?
        await tracker.load { first = $0 }
        #expect(first?.isCurrent == true)
        await tracker.load { _ in }
        #expect(first?.isCurrent == false)
        #expect(tracker.ticket.isCurrent)
    }

    @Test func anOlderLoadThatEndsLateDoesNotTouchTheNewerOne() async {
        let tracker = tracker(TestClock())
        let gate = Gate()

        let older = Task { @MainActor in
            await tracker.load { _ in
                await gate.wait()
                throw HedgerowError.unreachable("down")
            }
        }
        // Let the older load start and park at the gate.
        while !gate.isWaiting { await Task.yield() }

        await tracker.load { _ in }
        #expect(tracker.problem == nil)
        let loadedAt = tracker.lastLoaded
        #expect(loadedAt != nil)

        gate.open()
        await older.value
        // The older one failed after the newer one succeeded: nothing of it shows.
        #expect(tracker.problem == nil)
        #expect(tracker.lastLoaded == loadedAt)
        #expect(!tracker.isLoading)
    }

    @Test func whileTheNewerLoadRunsAnOlderEndDoesNotEndLoading() async {
        let tracker = tracker(TestClock())
        let olderGate = Gate()
        let newerGate = Gate()

        let older = Task { @MainActor in await tracker.load { _ in await olderGate.wait() } }
        while !olderGate.isWaiting { await Task.yield() }
        let newer = Task { @MainActor in await tracker.load { _ in await newerGate.wait() } }
        while !newerGate.isWaiting { await Task.yield() }

        olderGate.open()
        await older.value
        #expect(tracker.isLoading)

        newerGate.open()
        await newer.value
        #expect(!tracker.isLoading)
        #expect(tracker.lastLoaded != nil)
    }
}

/// Parks a load until the test lets it go on.
@MainActor private final class Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false

    var isWaiting: Bool { continuation != nil }

    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}

private struct FailingVault: TokenVault {
    func save(_ token: String, for id: UUID) throws {}
    func token(for id: UUID) throws -> String? { throw Boom() }
    func delete(for id: UUID) throws {}
}

@MainActor @Suite struct LoadedTokenTests {
    private let connection = Connection(name: "Home", baseURL: URL(string: "https://vole.example.com")!, kind: .vole)

    private func makeStore(_ vault: any TokenVault) throws -> (ConnectionStore, URL) {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("hedgerow-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("connections.json")
        return (try ConnectionStore(fileURL: file, vault: vault), file)
    }

    @Test func aSavedTokenIsReturned() throws {
        let vault = InMemoryVault()
        try vault.save("vv_token", for: connection.id)
        let (store, file) = try makeStore(vault)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        #expect(try loadedToken(for: connection, in: store).get() == "vv_token")
    }

    @Test func noTokenIsTheSameAsARejectedOne() throws {
        let (store, file) = try makeStore(InMemoryVault())
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        #expect(loadedToken(for: connection, in: store) == .failure(.tokenRejected))
    }

    @Test func aKeychainThatFailsIsUnreadable() throws {
        let (store, file) = try makeStore(FailingVault())
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        #expect(loadedToken(for: connection, in: store) == .failure(.tokenUnreadable))
    }
}

private func degraded(_ work: () async throws -> [Int]) async throws -> [Int] {
    try await orFallback([0], work)
}

@Suite struct OrFallbackTests {
    @Test func anAnswerPassesThrough() async throws {
        #expect(try await degraded { [1, 2] } == [1, 2])
    }

    @Test func anyFailureGivesTheFallback() async throws {
        #expect(try await degraded { throw HedgerowError.badResponse(404) } == [0])
        #expect(try await degraded { throw HedgerowError.badResponse(500) } == [0])
        #expect(try await degraded { throw HedgerowError.unauthorized } == [0])
        #expect(try await degraded { throw HedgerowError.unexpectedResponse } == [0])
        #expect(try await degraded { throw Boom() } == [0])
    }

    @Test func cancellationStillPropagates() async {
        await #expect(throws: CancellationError.self) {
            _ = try await degraded { throw CancellationError() }
        }
    }

    @Test func aFailureOfACancelledTaskPropagatesToo() async {
        let task = Task {
            try await degraded {
                withUnsafeCurrentTask { $0?.cancel() }
                throw HedgerowError.unreachable("down")
            }
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }
}
