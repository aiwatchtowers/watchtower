import GRDB
import SwiftUI

/// A view's database write, off the main thread (board #590).
///
/// The writer's busy callback sleeps on the thread that stepped the
/// statement, so a synchronous `dbPool.write` from a view froze the UI for up
/// to 5 s while another process held the write lock. `run` awaits GRDB's
/// writer queue instead (the same writer connection, so the lock metrics see
/// it unchanged) and hands the outcome back on the main actor:
/// - the caller changes its state only in `onSuccess` — a failed write keeps
///   the owner's draft, toggle or selection as it was;
/// - with `pending`, a call while the flag is up does nothing and the flag
///   stays up for the write's duration — one pending write per action, so a
///   second press while the first waits adds nothing twice. A view disables
///   its submit (and Cancel) on the same flag.
@MainActor
enum ViewWrite {
    /// Returns true when `updates` ran and committed.
    @discardableResult
    static func run<T: Sendable>(
        _ pool: DatabasePool,
        pending: Binding<Bool>? = nil,
        _ updates: @escaping @Sendable (Database) throws -> T,
        onSuccess: (T) -> Void,
        onFailure: (Error) -> Void
    ) async -> Bool {
        if let pending {
            guard !pending.wrappedValue else { return false }
            pending.wrappedValue = true
        }
        defer { pending?.wrappedValue = false }
        let value: T
        do {
            value = try await pool.write(updates)
        } catch {
            onFailure(error)
            return false
        }
        onSuccess(value)
        return true
    }
}

/// One pending write per key, for a view model's user actions (board #670).
///
/// A view model's write awaits the writer queue, so a second press can land
/// while the first still waits. `run` does nothing (returns nil) while a
/// write under the same key is pending: a toggle is never flipped twice, a
/// create never runs twice, and a read-modify-write of one row never builds
/// on the snapshot the first write is about to replace.
@MainActor
final class PendingWrites {
    private var keys: Set<AnyHashable> = []

    func isPending(_ key: AnyHashable) -> Bool {
        keys.contains(key)
    }

    /// Runs `body` unless a write under `key` is pending; nil when it did not run.
    @discardableResult
    func run<T>(_ key: AnyHashable, _ body: @MainActor () async -> T) async -> T? {
        guard keys.insert(key).inserted else { return nil }
        defer { keys.remove(key) }
        return await body()
    }
}
