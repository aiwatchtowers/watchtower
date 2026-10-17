import Foundation
import GRDB
import os
import WatchtowerCore
import WatchtowerSync

/// The `permission_request` slice (#517, spec §5.2), record name
/// `permission_request-<permission_requests.id>`: the `pending` permission
/// prompts of live board Claude sessions in the published workbenches
/// (`WorkbenchSlice`). An urgent kind on the fast lane, as `owner_ask` is.
///
/// Expiry (spec §4.2): a pending row older than the hook timeout, or of a
/// session that is not live, has no reader. `prepare` marks it `expired` in
/// its own short write before each read (the publisher runs it); `records`
/// leaves such rows out on its own, so a failed or late write never
/// publishes one. Liveness is `TerminalCenter.liveIDs` as the fast lane
/// copies it (`SessionLivenessBox`), the same the session slice uses. Until
/// the launch's reattach of the session host's runs is done
/// (`SessionLiveness.settled`), a session that survived the restart is not
/// live yet: the expiry then goes by age alone, and `records` only hides
/// the row (a hide is undone by the next pass, an `expired` write is not).
///
/// `summary_clipped` is Go's flag (the hook cut the summary at 2000 runes)
/// or the wire's own cap (`wireSummary`): the phone offers Deny only for it
/// (`PermissionAllowBlock`), and the hub refuses an allow the same way.
///
/// Wire shape: the Kit mirror `WatchtowerKit.PermissionRequest`.
struct PermissionRequestSlice: SliceSource {
    let kind = SliceKind.permissionRequest

    /// The hook's own timeout: past it no hook waits on the row. Go↔Swift
    /// dual path with `internal/devpack/workbench_settings.go`
    /// `permissionWaitSpec` (`timeoutSec: 86400`); change both together.
    static let maxAge: TimeInterval = 86_400
    /// Go clips the summary to 2000 runes; the wire caps it again in
    /// graphemes and says so.
    static let maxSummary = 2000

    /// The summary as the phone gets it, and whether it was shortened:
    /// by Go (`clippedByGo`, the row's `summary_clipped`) or by this cap.
    /// The hub's answer handler judges an allow on the same value.
    static func wireSummary(_ raw: String, clippedByGo: Bool) -> (text: String, clipped: Bool) {
        let clip = SliceClip.text(raw, limit: maxSummary)
        return (clip.text, clippedByGo || clip.clipped == true)
    }

    let liveness: @Sendable () -> SessionLiveness
    let now: @Sendable () -> Date

    init(liveness: @escaping @Sendable () -> SessionLiveness, now: @escaping @Sendable () -> Date = { Date() }) {
        self.liveness = liveness
        self.now = now
    }

    struct Payload: Encodable, Equatable {
        let id: Int64
        let sessionID: Int64
        let workbenchID: Int64
        let toolName: String
        let summary: String
        let summaryClipped: Bool? // swiftlint:disable:this discouraged_optional_boolean
        let createdAt: Date

        enum CodingKeys: String, CodingKey {
            case id
            case sessionID = "session_id"
            case workbenchID = "workbench_id"
            case toolName, summary, summaryClipped, createdAt
        }
    }

    func records(_ db: Database) throws -> [SliceRecord] {
        let published = Set(try WorkbenchSlice.publishedWorkbenchRefs(db).map(\.id))
        guard !published.isEmpty else { return [] }
        let stamp = now()
        let live = liveness().liveIDs
        let rows = try Row.fetchAll(db, sql: """
            SELECT r.id, r.terminal_session_id, r.workbench_id, r.tool_name, r.summary, r.summary_clipped,
                   r.created_at, s.project_id
            FROM permission_requests r
            JOIN terminal_sessions s ON s.id = r.terminal_session_id
            WHERE r.status = 'pending' AND s.kind = 'claude'
            ORDER BY r.id
            """)
        let encoder = RelayCoder.makeEncoder()
        return try rows.compactMap { row in
            let session: Int64 = row["terminal_session_id"]
            let project: Int64? = row["project_id"]
            let created = SliceDate.parse(row["created_at"] ?? "")
            guard let project, published.contains(project),
                  !Self.isStale(created: created, live: live.contains(session), now: stamp) else { return nil }
            let id: Int64 = row["id"]
            let summary = Self.wireSummary(row["summary"] ?? "", clippedByGo: row["summary_clipped"] ?? false)
            let payload = Payload(
                id: id, sessionID: session, workbenchID: row["workbench_id"], toolName: row["tool_name"] ?? "",
                summary: summary.text, summaryClipped: summary.clipped ? true : nil, createdAt: created ?? Date(timeIntervalSince1970: 0)
            )
            return SliceRecord(kind: kind, id: String(id), modifiedAt: stamp, payload: try encoder.encode(payload))
        }
    }

    /// The publisher's pre-read step: the expiry.
    func prepare(_ writer: any DatabaseWriter) throws {
        try expire(writer)
    }

    /// Marks `expired` every pending request no hook waits on any more;
    /// how many. Reads first and writes only when there is one, so a pass
    /// with nothing to expire takes no write lock. Before liveness settled
    /// only the age counts: every session reads as live.
    @discardableResult
    func expire(_ writer: any DatabaseWriter) throws -> Int {
        let stamp = now()
        let current = liveness()
        let live = current.liveIDs
        let pending = try writer.read { db in
            try Row.fetchAll(db, sql: "SELECT id, terminal_session_id, created_at FROM permission_requests WHERE status = 'pending'")
        }
        let stale: [Int64] = pending.compactMap { row in
            let session: Int64 = row["terminal_session_id"]
            let created = SliceDate.parse(row["created_at"] ?? "")
            let isLive = !current.settled || live.contains(session)
            return Self.isStale(created: created, live: isLive, now: stamp) ? row["id"] : nil
        }
        guard !stale.isEmpty else { return 0 }
        let expired = try writer.write { db in
            // The guard keeps an answer that landed since the read.
            try db.execute(
                sql: """
                    UPDATE permission_requests SET status = 'expired', decided_at = ?
                    WHERE status = 'pending' AND id IN (\(databaseQuestionMarks(count: stale.count)))
                    """,
                arguments: StatementArguments([SessionAgentStatus.formatStamp(stamp)] + stale.map { $0 as DatabaseValueConvertible })
            )
            return db.changesCount
        }
        Self.logger.info("expired \(expired) permission requests no hook waits on")
        return expired
    }

    /// No hook reads the row: its session is not live, or it is older than
    /// the hook timeout (an unreadable stamp, never written by Go, counts
    /// as old).
    static func isStale(created: Date?, live: Bool, now: Date) -> Bool {
        guard live, let created else { return true }
        return now.timeIntervalSince(created) > maxAge
    }

    private static let logger = Logger(subsystem: Constants.bundleID, category: "PermissionRequestSlice")
}
