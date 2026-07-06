import Foundation
import GRDB
import WatchtowerKit

/// Bridges the Kit's `ReplicaStore.fetchAll` into a live SwiftUI stream: sets up
/// a GRDB `ValueObservation` over `slice_records` for one `kind` and re-runs
/// `fetchAll` (typed decode) on every change, delivering results on the main
/// queue. The view models keep the returned cancellable alive.
///
/// The tracking closure reads `SELECT *` for the kind purely to register the
/// observed region (so payload updates, not just inserts/deletes, retrigger),
/// then delegates the actual decode to `fetchAll`. The app opens the store as a
/// `DatabasePool`, so this nested read runs on a separate reader connection.
enum ReplicaObserver {
    static func observe<T: FetchableRecord>(
        _ type: T.Type,
        kind: SliceKind,
        in store: ReplicaStore,
        onChange: @escaping @MainActor ([T]) -> Void
    ) -> AnyDatabaseCancellable {
        let observation = ValueObservation.tracking { db -> [T] in
            _ = try Row.fetchAll(db, sql: "SELECT * FROM slice_records WHERE kind = ?", arguments: [kind.rawValue])
            return try store.fetchAll(T.self, kind: kind)
        }
        return observation.start(
            in: store.reader,
            scheduling: .async(onQueue: .main),
            onError: { print("observation error for \(kind.rawValue): \($0)") },
            onChange: { value in MainActor.assumeIsolated { onChange(value) } }
        )
    }
}
