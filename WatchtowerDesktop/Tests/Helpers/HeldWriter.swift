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
        let failure = Locked<Error?>(nil)
        Thread.detachNewThread {
            do {
                try pool.write { _ in
                    entered.signal()
                    gate.wait()
                }
            } catch {
                // A write that never entered still wakes the waiting init.
                failure.set(error)
                entered.signal()
            }
        }
        entered.wait() // the writer queue is taken (or the write failed): the detached write's own signal, no clock
        if let error = failure.get() {
            XCTFail("HeldWriter could not take the writer: \(error)", file: file, line: line)
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

/// What `task` returned, awaited with no clock and no deadline (a task that
/// never finishes is a hang the lane watchdog reports). Optional so the
/// existing `XCTUnwrap(await boundedValue(…))` call sites read the same.
@MainActor
func boundedValue<T>(_ task: Task<T, Never>) async -> T? {
    await task.value
}

/// A value read and written from two threads.
private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func get() -> Value { lock.withLock { value } }
    func set(_ new: Value) { lock.withLock { value = new } }
}
