import Foundation
import GRDB
import WatchtowerSync

/// The ordered outbox as the phone shows it (relay client Phase 1): actions waiting to be written (`queued`),
/// actions listed under Not delivered (`undelivered`), and whether the last flush the session ran stopped on a
/// refusal (no network, a rate limit). A hub on today's path keeps it empty: its rows carry no delivery state.
struct OutboxBacklog: Equatable {
    var queued: Int
    var undelivered: Int
    var lastFlushStopped: Bool

    static let empty = Self(queued: 0, undelivered: 0, lastFlushStopped: false)

    /// The two counts as the replica holds them.
    struct Counts: Equatable {
        let queued: Int
        let undelivered: Int
    }

    /// Follows `ReplicaStore.outboxCounts` for the session's lifetime: re-read when `pending_actions` changes, a
    /// read that leaves the counts equal publishes nothing.
    @MainActor
    static func observe(store: ReplicaStore, onChange: @escaping @MainActor (Counts) -> Void) -> ResilientObservation {
        ResilientObservation(
            name: "outbox-backlog",
            reader: store.reader,
            observation: {
                ValueObservation.tracking { db in
                    let counts = try store.outboxCounts(from: db)
                    return Counts(queued: counts.queued, undelivered: counts.undelivered)
                }
                .removeDuplicates()
            },
            onChange: onChange
        )
    }
}
