import Foundation
import GRDB
import os
import WatchtowerKit

/// Bridges the Kit's `ReplicaStore.fetchAll` into a live SwiftUI stream: sets up
/// a GRDB `ValueObservation` over `slice_records` for one `kind` and re-runs
/// `fetchAll` (typed decode) on every change, delivering results on the main
/// queue. The view models keep the returned cancellable alive.
///
/// The tracking closure decodes via `fetchAll(_:kind:from:)` on the closure's
/// OWN `db` — a single read that both registers the observed region (so payload
/// updates, not just inserts/deletes, retrigger) and returns the typed models.
/// It must NOT call the `writer.read`-wrapping `fetchAll(_:kind:)`: the closure
/// already runs on a pool reader connection, and a nested `DatabasePool.read`
/// traps on reentrancy (`fatalError`, release and debug).
enum ReplicaObserver {
    private static let logger = Logger(subsystem: "WatchtowerMobile", category: "ReplicaObserver")

    static func observe<T: FetchableRecord>(
        _ type: T.Type,
        kind: SliceKind,
        in store: ReplicaStore,
        onChange: @escaping @MainActor ([T]) -> Void
    ) -> AnyDatabaseCancellable {
        let observation = ValueObservation.tracking { db -> [T] in
            try store.fetchAll(T.self, kind: kind, from: db)
        }
        return observation.start(
            in: store.reader,
            scheduling: .async(onQueue: .main),
            onError: {
                Self.logger.error("observation error for \(kind.rawValue, privacy: .public): \($0.localizedDescription, privacy: .public)")
            },
            onChange: { value in MainActor.assumeIsolated { onChange(value) } }
        )
    }

    /// Same bridge, but the tracking closure ALSO reads the `pending_actions`
    /// overlay — both through from-db overloads on the closure's own `db`
    /// (the pool-reentrancy rule above applies to EVERY read inside the
    /// closure). One observation spanning both tables delivers slice rows and
    /// their overlay as a single consistent snapshot, so there is never a
    /// frame where a chip and its host row disagree about a write.
    static func observeWithPendingActions<T: FetchableRecord>(
        _ type: T.Type,
        kind: SliceKind,
        in store: ReplicaStore,
        onChange: @escaping @MainActor ([T], [PendingAction]) -> Void
    ) -> AnyDatabaseCancellable {
        let observation = ValueObservation.tracking { db -> ([T], [PendingAction]) in
            (try store.fetchAll(T.self, kind: kind, from: db),
             try store.pendingActions(from: db))
        }
        return observation.start(
            in: store.reader,
            scheduling: .async(onQueue: .main),
            onError: {
                Self.logger.error("observation error for \(kind.rawValue, privacy: .public)+pending: \($0.localizedDescription, privacy: .public)")
            },
            onChange: { value in MainActor.assumeIsolated { onChange(value.0, value.1) } }
        )
    }
}
