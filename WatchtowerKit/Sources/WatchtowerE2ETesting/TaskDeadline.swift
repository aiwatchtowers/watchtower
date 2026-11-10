import Foundation

/// A test awaited a task that did not finish inside its deadline (#1500).
public struct TaskDeadlineExceeded: Error, CustomStringConvertible {
    public let what: String
    public let seconds: Double
    public var description: String { "\(what) did not finish within \(seconds) s" }
}

private final class DeadlineGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    init(_ continuation: CheckedContinuation<Value, Error>) { self.continuation = continuation }

    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        let held = continuation
        continuation = nil
        lock.unlock()
        held?.resume(with: result)
    }
}

extension Task {
    /// `await task.value` with a deadline: a stuck task fails the test with `what` instead of hanging the run.
    /// On a timeout the task is cancelled (best effort) and `TaskDeadlineExceeded` is thrown. A task that
    /// throws rethrows its own error.
    public func value(
        within seconds: Double = 60, _ what: String = "task"
    ) async throws -> Success where Success: Sendable {
        let task = self
        return try await withCheckedThrowingContinuation { continuation in
            let gate = DeadlineGate<Success>(continuation)
            Task<Void, Never> {
                do { gate.finish(.success(try await task.value)) } catch { gate.finish(.failure(error)) }
            }
            Task<Void, Never> {
                try? await Task<Never, Never>.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                task.cancel()
                gate.finish(.failure(TaskDeadlineExceeded(what: what, seconds: seconds)))
            }
        }
    }
}
