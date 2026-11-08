import Foundation
import GRDB
import WatchtowerSync

/// The ordered outbox as the phone shows it (relay client Phase 1): actions waiting to be written (`queued`),
/// actions written and not yet answered (`sent`), actions listed under Not delivered (`undelivered`), whether the
/// last flush the session ran stopped on a refusal (no network, a rate limit), and since when the relay feed is
/// parked waiting for the Mac's new keys (Phase 5, S58). A hub on today's path keeps it empty: its rows carry no
/// delivery state, and its feed never parks.
struct OutboxBacklog: Equatable {
    var queued: Int
    var sent: Int
    var undelivered: Int
    var lastFlushStopped: Bool
    /// `relay_feed_parked_since`: written by the relay feed when it parks, removed when a read finds no record
    /// waiting for keys. nil: the feed reads.
    var feedParkedSince: Date?

    static let empty = Self(queued: 0, sent: 0, undelivered: 0, lastFlushStopped: false, feedParkedSince: nil)

    /// What the replica holds: the three counts and the parked mark.
    struct Counts: Equatable {
        let queued: Int
        let sent: Int
        let undelivered: Int
        let feedParkedSince: Date?

        /// One read of `pending_actions` and the parked mark, so an observation tracks both tables.
        static func read(_ store: ReplicaStore, _ db: Database) throws -> Self {
            let counts = try store.outboxCounts(from: db)
            return Self(
                queued: counts.queued, sent: counts.sent, undelivered: counts.undelivered,
                feedParkedSince: try store.relayFeedParkedSince(from: db))
        }
    }

    /// Takes the replica's side; `lastFlushStopped` is the session's own.
    mutating func apply(_ counts: Counts) {
        queued = counts.queued
        sent = counts.sent
        undelivered = counts.undelivered
        feedParkedSince = counts.feedParkedSince
    }

    /// Follows the replica for the session's lifetime: re-read when `pending_actions` or `replica_meta` changes, a
    /// read that leaves the counts equal publishes nothing.
    @MainActor
    static func observe(store: ReplicaStore, onChange: @escaping @MainActor (Counts) -> Void) -> ResilientObservation {
        ResilientObservation(
            name: "outbox-backlog",
            reader: store.reader,
            observation: {
                ValueObservation.tracking { db in try Counts.read(store, db) }
                    .removeDuplicates()
            },
            onChange: onChange
        )
    }
}
