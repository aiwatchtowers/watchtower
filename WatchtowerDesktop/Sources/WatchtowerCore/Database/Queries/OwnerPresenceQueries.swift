import Foundation
import GRDB

/// The `owner_presence` singleton (migration 00107, spec
/// 2026-10-10-owner-asks-v2 Part 2.2–2.3): which session the owner is in,
/// written by the Desktop only and read by Go (`db.OwnerPresentIn`, which
/// trusts a write for 90 s).
package enum OwnerPresenceQueries {
    /// Entering a session, every heartbeat while in it, and leaving it (a nil
    /// `sessionID`: no session, after the debounce, on lock, sleep and quit)
    /// are this one upsert, so a failed write is recovered by the next one.
    /// `seen_at` gets `at` in the `agent_state_at` layout.
    package static func upsert(_ db: Database, sessionID: Int64?, at: Date) throws {
        try db.execute(
            sql: """
                INSERT INTO owner_presence (id, session_id, seen_at) VALUES (1, ?, ?)
                ON CONFLICT(id) DO UPDATE SET session_id = excluded.session_id, seen_at = excluded.seen_at
                """,
            arguments: [sessionID, SessionAgentStatus.formatStamp(at)]
        )
    }
}
