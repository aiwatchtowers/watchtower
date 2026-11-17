import Foundation
import GRDB

/// One `chat_turn_leases` row (spec 2026-11-15 iPhone chat §4.4): who runs
/// the conversation's turn now. Every time is Unix epoch milliseconds (UTC),
/// compared as a number; the callers pass the clock in. Go twin:
/// `internal/db/chat_lease.go`, both run `chat_lease_cases.json`.
package struct ChatLease: Equatable, Sendable, FetchableRecord {
    package enum Owner: String, Sendable {
        case desktop, hub
    }

    /// A heartbeat older than this lets anyone take the lease (Go `ChatLeaseStaleMS`).
    package static let staleAfterMS: Int64 = 60_000
    /// This app launch's `owner_id`: a lease left by an earlier launch is
    /// released at launch (spec §5).
    package static let desktopLaunchID = UUID().uuidString

    package let conversationID: Int64
    package let owner: Owner
    package let ownerID: String
    package let turnID: String
    package let startedAtMS: Int64
    package let heartbeatAtMS: Int64
    package let cancelRequestedAtMS: Int64?

    package init(
        conversationID: Int64,
        owner: Owner,
        ownerID: String,
        turnID: String,
        startedAtMS: Int64,
        heartbeatAtMS: Int64,
        cancelRequestedAtMS: Int64? = nil
    ) {
        self.conversationID = conversationID
        self.owner = owner
        self.ownerID = ownerID
        self.turnID = turnID
        self.startedAtMS = startedAtMS
        self.heartbeatAtMS = heartbeatAtMS
        self.cancelRequestedAtMS = cancelRequestedAtMS
    }

    package init(row: Row) throws {
        conversationID = row["conversation_id"]
        let raw: String = row["owner"]
        guard let owner = Owner(rawValue: raw) else {
            throw DatabaseError(resultCode: .SQLITE_MISMATCH, message: "unknown chat lease owner \(raw)")
        }
        self.owner = owner
        ownerID = row["owner_id"]
        turnID = row["turn_id"]
        startedAtMS = row["started_at_ms"]
        heartbeatAtMS = row["heartbeat_at_ms"]
        cancelRequestedAtMS = row["cancel_requested_at_ms"]
    }

    /// Nobody may take it at `nowMS`: its heartbeat is at most `staleAfterMS` old.
    package func isLive(nowMS: Int64) -> Bool {
        heartbeatAtMS >= nowMS - Self.staleAfterMS
    }

    /// `date` as Unix epoch milliseconds.
    package static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
    }
}

/// The claim was refused: another turn holds a live lease on the
/// conversation, so nothing of this turn was written (CHAT-01 order).
package struct ChatBusyError: LocalizedError, Equatable {
    package init() {}

    package var errorDescription: String? {
        "This chat is answering elsewhere. Your message wasn't sent; try again when the answer ends."
    }
}

/// The SQL of `chat_turn_leases`, the same operations as Go's
/// `internal/db/chat_lease.go`.
package enum ChatLeaseQueries {

    /// The conversation's lease, or nil.
    package static func fetch(_ db: Database, conversationID: Int64) throws -> ChatLease? {
        try ChatLease.fetchOne(db, sql: "SELECT * FROM chat_turn_leases WHERE conversation_id = ?",
                               arguments: [conversationID])
    }

}
