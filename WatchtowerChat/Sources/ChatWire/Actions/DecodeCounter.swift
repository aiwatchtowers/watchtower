import Foundation

/// A thread-safe counter (a test seam for work a view must not repeat).
public final class DecodeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    public init() {}

    public func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
