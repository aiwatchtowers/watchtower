import Foundation
import GRDB
import os

/// Pushes the product slice (briefings, inbox, targets, …) from the local DB
/// to the cloud transport. Runs a poll loop (not ValueObservation — the Go
/// daemon writes via its own connection, so observation never fires; see
/// InboxViewModel.startPolling), diffing rows against `HubSyncState` hashes
/// so only changed records hit the transport.
final class SlicePublisher: Sendable {
    private let dbPool: DatabasePool
    private let state: HubSyncState
    private let transport: any CloudSyncTransport & Sendable
    private let logger = Logger(subsystem: Constants.bundleID, category: "SlicePublisher")
    private let pollTask = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

    init(dbPool: DatabasePool, state: HubSyncState, transport: any CloudSyncTransport & Sendable) {
        self.dbPool = dbPool
        self.state = state
        self.transport = transport
    }

    /// The v1 slice window per kind — single source of truth for what syncs.
    /// Column names verified against internal/db/schema.sql:
    /// - inbox_items has no 'archived' status; archived-ness is `archived_at`.
    /// - targets' terminal state is 'dismissed' (no 'archived' in its CHECK).
    /// - tracks has `dismissed_at` ('' = active), not a `dismissed` flag.
    /// - calendar_events.start_time is ISO8601 with 'T'/'Z'; wrap in datetime()
    ///   so comparison against datetime('now', …) output is well-defined.
    static let sliceSQL: [SliceKind: String] = [
        .briefing: "SELECT * FROM briefings ORDER BY id DESC LIMIT 30",
        .inboxItem: "SELECT * FROM inbox_items WHERE archived_at IS NULL ORDER BY id DESC LIMIT 200",
        .target: "SELECT * FROM targets WHERE status != 'dismissed' ORDER BY id DESC LIMIT 300",
        .track: "SELECT * FROM tracks WHERE dismissed_at = '' ORDER BY id DESC LIMIT 200",
        .digest: "SELECT * FROM digests ORDER BY id DESC LIMIT 50",
        .digestTopic: """
            SELECT * FROM digest_topics
            WHERE digest_id IN (SELECT id FROM digests ORDER BY id DESC LIMIT 50)
            """,
        .calendarEvent: """
            SELECT * FROM calendar_events
            WHERE datetime(start_time) >= datetime('now', '-1 day')
              AND datetime(start_time) <= datetime('now', '+14 days')
            """,
        .personCard: "SELECT * FROM people_cards ORDER BY id DESC LIMIT 100"
    ]

    // MARK: - Publishing

    /// One full push cycle over all slice kinds. Returns what happened;
    /// skipped (un-encodable) records are also logged once per cycle.
    @discardableResult
    func publishOnce() async throws -> (pushed: Int, deleted: Int, skipped: [String]) {
        var pushed = 0
        var deleted = 0
        var skipped: [String] = []
        let now = Date()
        let startGen = try state.generation()

        for kind in SliceKind.allCases {
            guard let sql = Self.sliceSQL[kind] else { continue }
            let fetched = try fetchSliceRows(sql: sql)
            let rows: [(id: String, row: Row)] = fetched.map { (id: Self.rowID($0), row: $0) }
            let result = SliceDiff.compute(
                kind: kind,
                rows: rows,
                knownHashes: try state.hashes(forKind: kind),
                now: now
            )

            if !result.upserts.isEmpty {
                try await transport.save(result.upserts.map { CloudRecordFactory.record(for: $0) })
                // Guard: abort if a mid-cycle account reset wiped the state.
                // The next cycle will re-diff against empty hashes and re-push everything.
                guard try state.generation() == startGen else {
                    logger.warning("publishOnce: generation changed mid-cycle — aborting to avoid recording stale hashes")
                    return (pushed, deleted, skipped)
                }
                for record in result.upserts {
                    try state.setHash(SliceDiff.hashHex(record.payload), for: record.recordName)
                }
                pushed += result.upserts.count
            }
            if !result.deletions.isEmpty {
                try await transport.delete(recordNames: result.deletions, in: .data)
                guard try state.generation() == startGen else {
                    logger.warning("publishOnce: generation changed mid-cycle — aborting to avoid recording stale hashes")
                    return (pushed, deleted, skipped)
                }
                try state.removeHashes(result.deletions)
                deleted += result.deletions.count
            }
            skipped.append(contentsOf: result.skipped)
        }

        if !skipped.isEmpty {
            logger.warning("skipped \(skipped.count) un-encodable slice records: \(skipped.joined(separator: ", "), privacy: .public)")
        }
        return (pushed, deleted, skipped)
    }

    /// Synchronous on purpose: GRDB's async `read` requires `T: Sendable`,
    /// and `Row` is explicitly non-Sendable in GRDB 7, so `[Row]` can never
    /// go through the async overload — local toolchains masked this by
    /// accepting `await` on the sync overload, CI's does not. In a non-async
    /// function only the sync overload exists; nothing is left to resolve.
    private func fetchSliceRows(sql: String) throws -> [Row] {
        try dbPool.read { db in
            try Row.fetchAll(db, sql: sql)
        }
    }

    // MARK: - Poll loop

    func start(interval: Duration = .seconds(60)) {
        let task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                do {
                    _ = try await self.publishOnce()
                } catch {
                    self.logger.error("publish cycle failed: \(error.localizedDescription, privacy: .public)")
                }
                try? await Task.sleep(for: interval)
            }
        }
        pollTask.withLock { current in
            current?.cancel()
            current = task
        }
    }

    func stop() {
        pollTask.withLock { current in
            current?.cancel()
            current = nil
        }
    }

    // MARK: - Helpers

    /// Slice ids are INTEGER for most tables but TEXT for calendar_events,
    /// so read the raw storage instead of forcing an Int64 conversion
    /// (which would fatalError on TEXT primary keys in GRDB).
    private static func rowID(_ row: Row) -> String {
        let dbValue: DatabaseValue = row["id"] ?? .null
        switch dbValue.storage {
        case .int64(let value):
            return String(value)
        case .string(let value):
            return value
        default:
            return "0"
        }
    }
}
