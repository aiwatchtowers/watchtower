import Foundation

public enum RollbackVerdict: Equatable, Sendable { case newer, same, older }

/// F3: keyed by (wire name, sender). One relay wire name carries the phone's p2h envelope (the phone's seq space)
/// and later the hub's h2p echo (the hub's seq space); a guard keyed by the name alone would drop a valid echo.
/// Versions compare as (epoch, seq), epoch first.
public protocol RollbackGuard: Sendable {
    /// .newer: store and use; .same: an identical re-delivery (idempotent); .older: ignore (rollback).
    func check(wireName: String, senderID: UUID, epoch: UInt32, seq: UInt64) throws -> RollbackVerdict
    func record(wireName: String, senderID: UUID, epoch: UInt32, seq: UInt64) throws
}

/// Process-lifetime guard: tests, and any side without a persisted one.
public final class InMemoryRollbackGuard: RollbackGuard, @unchecked Sendable {
    private struct Key: Hashable {
        let wireName: String
        let senderID: UUID
    }

    private struct Version: Comparable {
        let epoch: UInt32
        let seq: UInt64

        static func < (lhs: Self, rhs: Self) -> Bool { (lhs.epoch, lhs.seq) < (rhs.epoch, rhs.seq) }
    }

    private let lock = NSLock()
    private var seen: [Key: Version] = [:]

    public init() {}

    public func check(wireName: String, senderID: UUID, epoch: UInt32, seq: UInt64) throws -> RollbackVerdict {
        let incoming = Version(epoch: epoch, seq: seq)
        guard let stored = lock.withLock({ seen[Key(wireName: wireName, senderID: senderID)] }) else { return .newer }
        if incoming == stored { return .same }
        return incoming > stored ? .newer : .older
    }

    /// Keeps the highest version seen.
    public func record(wireName: String, senderID: UUID, epoch: UInt32, seq: UInt64) throws {
        let incoming = Version(epoch: epoch, seq: seq)
        lock.withLock {
            let key = Key(wireName: wireName, senderID: senderID)
            if let stored = seen[key], stored >= incoming { return }
            seen[key] = incoming
        }
    }
}
