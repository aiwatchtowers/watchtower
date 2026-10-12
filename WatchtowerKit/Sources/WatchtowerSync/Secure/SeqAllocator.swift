import Foundation

public enum SeqAllocatorError: Error, Equatable { case exhausted }

/// Monotonic u64 counter with block reservation: persists `ceiling = next + blockSize` before handing out
/// a value of a new block, so a crash skips ahead and never reuses a seq. Values start at 1; 0 means "none".
public final class SeqAllocator: @unchecked Sendable {
    private let blockSize: UInt64
    private let load: @Sendable () throws -> UInt64
    private let store: @Sendable (UInt64) throws -> Void
    private let lock = NSLock()
    private var loaded = false
    private var current: UInt64 = 0
    private var ceiling: UInt64 = 0

    public init(
        blockSize: UInt64 = 1_024,
        load: @escaping @Sendable () throws -> UInt64,
        store: @escaping @Sendable (UInt64) throws -> Void
    ) {
        self.blockSize = max(blockSize, 1)
        self.load = load
        self.store = store
    }

    public func next() throws -> UInt64 {
        try lock.withLock {
            if !loaded {
                // 0 is reserved as "none" for the rollback guards: the first value ever handed out is 1.
                let stored = try load()
                current = max(stored, 1)
                ceiling = stored
                loaded = true
            }
            if current >= ceiling {
                let (newCeiling, overflow) = current.addingReportingOverflow(blockSize)
                guard !overflow else { throw SeqAllocatorError.exhausted }
                try store(newCeiling)
                ceiling = newCeiling
            }
            defer { current += 1 }
            return current
        }
    }
}
