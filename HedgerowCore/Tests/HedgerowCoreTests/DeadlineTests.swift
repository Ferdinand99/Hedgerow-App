import Foundation
import Testing
@testable import HedgerowCore

@Suite struct DeadlineTests {
    @Test func returnsTheResultOfAFastOperation() async throws {
        let value = try await withDeadline(.seconds(5)) { 42 }
        #expect(value == 42)
    }

    @Test func slowOperationTimesOutAsUnreachable() async throws {
        let started = ContinuousClock.now
        await #expect(throws: HedgerowError.unreachable("timed out")) {
            try await withDeadline(.milliseconds(100)) {
                try await Task.sleep(for: .seconds(60))
            }
        }
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func operationErrorsPassThrough() async throws {
        await #expect(throws: HedgerowError.unauthorized) {
            try await withDeadline(.seconds(5)) { () async throws -> Int in throw HedgerowError.unauthorized }
        }
    }

    @Test func cancellingTheCallerCancelsTheOperation() async throws {
        let task = Task {
            try await withDeadline(.seconds(60)) {
                try await Task.sleep(for: .seconds(60))
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let started = ContinuousClock.now
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ContinuousClock.now - started < .seconds(5))
    }
}
