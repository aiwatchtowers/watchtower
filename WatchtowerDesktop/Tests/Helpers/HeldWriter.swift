import Foundation
import GRDB
import XCTest

/// Holds a pool's GRDB writer queue until `release()`, as a busy database
/// would (board #670): every write queued meanwhile waits behind it, the
/// main actor does not. `release()` is idempotent, so a test both releases
/// where its scenario needs it and in a `defer`, and a failing test never
/// leaves the writer held.
final class HeldWriter: @unchecked Sendable {
    private let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var released = false

    init(_ pool: DatabasePool, file: StaticString = #filePath, line: UInt = #line) {
        let entered = DispatchSemaphore(value: 0)
        let gate = gate
        Thread.detachNewThread {
            try? pool.write { _ in
                entered.signal()
                gate.wait()
            }
        }
        if entered.wait(timeout: .now() + 5) == .timedOut {
            XCTFail("the writer queue was not taken", file: file, line: line)
        }
    }

    func release() {
        lock.lock()
        defer { lock.unlock() }
        guard !released else { return }
        released = true
        gate.signal()
    }
}

/// What a task the test cannot trust to finish returned: nil when it did
/// not finish within `timeout`, so a regression fails the test instead of
/// hanging the suite.
@MainActor
func boundedValue<T>(_ task: Task<T, Never>, timeout: Duration = .seconds(5)) async -> T? {
    let outcome = TaskOutcome<T>()
    Task { @MainActor in
        outcome.value = await task.value
        outcome.done = true
    }
    let start = ContinuousClock.now
    while !outcome.done, ContinuousClock.now - start < timeout {
        try? await Task.sleep(for: .milliseconds(5))
    }
    return outcome.value
}

@MainActor
private final class TaskOutcome<T> {
    var value: T?
    var done = false
}
