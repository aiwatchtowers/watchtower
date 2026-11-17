import Foundation
import GRDB
import XCTest

/// Holds a pool's GRDB writer queue until `release()`, as a busy database
/// would (board #670): every write queued meanwhile waits behind it, the
/// main actor does not. `release()` is idempotent, so a test both releases
/// where its scenario needs it and in a `defer`, and a failing test never
/// leaves the writer held.
///
/// `init` waits for the detached write to take the writer. The one way that
/// wait never ends — the pool's writer is already held by another
/// unreleased `HeldWriter` — is refused up front by name instead of
/// blocking the main thread: no clock, no deadline.
final class HeldWriter: @unchecked Sendable {
    /// Pools a live `HeldWriter` holds, so a second hold of the same pool
    /// fails at once instead of waiting forever behind the first.
    private static let heldPools = Locked<Set<ObjectIdentifier>>([])

    private let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var released = false
    private let poolID: ObjectIdentifier?

    /// False when the hold was refused (the failure was reported through `fail`).
    let isHolding: Bool

    init(
        _ pool: DatabasePool,
        file: StaticString = #filePath,
        line: UInt = #line,
        fail: (String, StaticString, UInt) -> Void = { XCTFail($0, file: $1, line: $2) }
    ) {
        let id = ObjectIdentifier(pool)
        let claimed = Self.heldPools.update { held in held.insert(id).inserted }
        guard claimed else {
            poolID = nil
            isHolding = false
            released = true
            fail("HeldWriter: this pool's writer is already held by another HeldWriter; release it first", file, line)
            return
        }
        poolID = id
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
            isHolding = false
            Self.heldPools.update { held in held.remove(id) }
            fail("HeldWriter could not take the writer: \(error)", file, line)
        } else {
            isHolding = true
        }
    }

    func release() {
        lock.lock()
        defer { lock.unlock() }
        guard !released else { return }
        released = true
        if let poolID { Self.heldPools.update { held in held.remove(poolID) } }
        gate.signal()
    }
}

/// What `task` returned, or nil when it has not finished within `turns`
/// main-actor turns (`Task.yield`). Bounded by a count, never by a clock: a
/// task stuck behind a held writer is cancelled and the caller's
/// `XCTUnwrap`/`XCTAssertNotNil` fails with its name instead of hanging the
/// shard.
@MainActor
func boundedValue<T>(_ task: Task<T, Never>, turns: Int = 1_000_000) async -> T? {
    let outcome = Outcome<T>()
    let waiter = Task { @MainActor in
        outcome.value = await task.value
        outcome.finished = true
    }
    for _ in 0..<turns where !outcome.finished { await Task.yield() }
    if outcome.finished { return outcome.value }
    task.cancel()
    waiter.cancel()
    return nil
}

/// The waiter's result, read and written on the main actor only.
@MainActor
private final class Outcome<T> {
    var value: T?
    var finished = false
}

/// A value read and written from two threads.
private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func get() -> Value { lock.withLock { value } }
    func set(_ new: Value) { lock.withLock { value = new } }
    @discardableResult
    func update<R>(_ body: (inout Value) -> R) -> R { lock.withLock { body(&value) } }
}
