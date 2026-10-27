import Foundation

/// Runs `operation` and gives up after `limit`: the operation is cancelled and
/// `HedgerowError.unreachable` is thrown, so a slow server cannot hold a screen for ever.
/// Cancelling the caller cancels the operation and throws `CancellationError`.
public func withDeadline<T: Sendable>(
    _ limit: Duration, operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: limit)
            throw HedgerowError.unreachable("timed out")
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw CancellationError() }
        return first
    }
}
