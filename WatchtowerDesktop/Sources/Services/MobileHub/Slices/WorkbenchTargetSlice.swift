import Foundation
import GRDB
import WatchtowerCore
import WatchtowerSync

/// Which board targets the hub publishes (mobile POC spec §4.3), one
/// definition for the target, comment and workbench slices. Per workbench:
/// every non-archived target, ≤ 2000, newest `updated_at` first; plus the
/// archived ones whose last close is in the last 90 days, ≤ 500, newest
/// close first. Board targets only (`project_id IS NOT NULL`, PROJ-01); the
/// archive verdict is the `workbench_target_archive` view's (PROJ-15), read
/// once for all workbenches.
struct WorkbenchTargetWindow {
    static let maxOpen = 2000
    static let maxArchived = 500
    static let archivedDays = 90

    /// target id → archived, for every published target.
    let published: [Int64: Bool]
    /// workbench id → board targets left out of the window.
    let more: [Int64: Int]
    /// workbench id → `done` targets that are not archived.
    let doneUnarchived: [Int64: Int]

    static func load(_ db: Database, now: Date) throws -> Self {
        let cutoff = now.addingTimeInterval(-Double(archivedDays) * 86_400)
        // The close time is the view's own: the newest status move, else
        // updated_at. Every non-archived target is in the window, so the done
        // count reads from it too.
        let rows = try Row.fetchAll(db, sql: """
            WITH board AS (
                SELECT t.id, t.project_id, t.status, t.updated_at, a.archived,
                       COALESCE((SELECT MAX(h.changed_at) FROM target_status_history h WHERE h.target_id = t.id),
                                t.updated_at) AS closed_at
                FROM targets t
                JOIN workbench_target_archive a ON a.target_id = t.id
                WHERE t.project_id IS NOT NULL
            )
            SELECT id, project_id, status, archived,
                   ROW_NUMBER() OVER (
                       PARTITION BY project_id, archived
                       ORDER BY CASE WHEN archived THEN closed_at ELSE updated_at END DESC, id DESC
                   ) AS rank
            FROM board
            WHERE archived = 0 OR julianday(closed_at) >= julianday(?)
            """, arguments: [cutoff])
        var published: [Int64: Bool] = [:]
        var more: [Int64: Int] = [:]
        var done: [Int64: Int] = [:]
        for row in rows {
            let project: Int64 = row["project_id"]
            let archived: Bool = row["archived"]
            if !archived, row["status"] as String == "done" { done[project, default: 0] += 1 }
            let rank: Int = row["rank"]
            if rank <= (archived ? maxArchived : maxOpen) {
                published[row["id"]] = archived
            } else {
                more[project, default: 0] += 1
            }
        }
        return Self(published: published, more: more, doneUnarchived: done)
    }
}

/// The `workbench_target` slice (mobile POC spec §4.3), record name
/// `workbench_target-<targets.id>`: the published workbenches' board targets
/// inside `WorkbenchTargetWindow`, from `WorkbenchQueries.board` (tree,
/// comment counters, archive flag), resolved and capped.
///
/// Wire shape: the Kit mirror `WatchtowerKit.WorkbenchTarget`.
struct WorkbenchTargetSlice: SliceSource {
    let kind = SliceKind.workbenchTarget

    static let maxSessionIDs = 20

    let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    struct Payload: Encodable, Equatable {
        let id: Int64
        let workbenchID: Int64
        let parentID: Int64?
        let text: String
        let textClipped: Bool? // swiftlint:disable:this discouraged_optional_boolean
        let intent: String
        let intentClipped: Bool? // swiftlint:disable:this discouraged_optional_boolean
        let status: String
        let priority: String
        let progress: Double
        let branch: String
        let branchClipped: Bool? // swiftlint:disable:this discouraged_optional_boolean
        let pr: String
        let prClipped: Bool? // swiftlint:disable:this discouraged_optional_boolean
        let archived: Bool
        let childrenCount: Int
        let openComments: Int
        let unreadForOwner: Int
        let openAsks: Int
        let sessionIDs: [Int64]
        let sessionIDsMore: Int?
        let lastStatusAt: Date?
        let lastStatusActor: String?
        let workOnPrompt: String
        let workOnPromptClipped: Bool? // swiftlint:disable:this discouraged_optional_boolean
        let createdAt: Date
        let updatedAt: Date

        // RelayCoder's convertToSnakeCase would split "IDs" into "i_ds".
        enum CodingKeys: String, CodingKey {
            case id
            case workbenchID = "workbench_id"
            case parentID = "parent_id"
            case text, textClipped, intent, intentClipped, status, priority, progress
            case branch, branchClipped, pr, prClipped, archived, childrenCount, openComments, unreadForOwner, openAsks
            case sessionIDs = "session_ids"
            case sessionIDsMore = "session_ids_more"
            case lastStatusAt, lastStatusActor, workOnPrompt, workOnPromptClipped, createdAt, updatedAt
        }
    }

    func records(_ db: Database) throws -> [SliceRecord] {
        let workbenches = try WorkbenchSlice.publishedWorkbenches(db)
        guard !workbenches.isEmpty else { return [] }
        let window = try WorkbenchTargetWindow.load(db, now: now())
        let facts = try TargetFacts.load(db)
        let encoder = RelayCoder.makeEncoder()
        let stamp = now()
        var records: [SliceRecord] = []
        for workbench in workbenches {
            var stack = try WorkbenchQueries.board(db, projectID: workbench.id).map { (node: $0, parent: Int64?.none) }
            while let (node, parent) = stack.popLast() {
                let id = Int64(node.target.id)
                stack.append(contentsOf: node.children.map { (node: $0, parent: id) })
                guard let archived = window.published[id] else { continue }
                let payload = makePayload(node, workbenchID: workbench.id, parentID: parent, archived: archived, facts: facts)
                records.append(SliceRecord(kind: kind, id: String(id), modifiedAt: stamp, payload: try encoder.encode(payload)))
            }
        }
        return records
    }

    private func makePayload(
        _ node: WorkbenchBoardNode,
        workbenchID: Int64,
        parentID: Int64?,
        archived: Bool,
        facts: TargetFacts
    ) -> Payload {
        let target = node.target
        let id = Int64(target.id)
        let text = SliceClip.text(target.text, limit: 300)
        let intent = SliceClip.text(target.intent, limit: 4000)
        let branch = SliceClip.text(target.branch, limit: 120)
        let pr = SliceClip.text(target.pr, limit: 120)
        let sessions = SliceClip.list(facts.sessions[id] ?? [], limit: Self.maxSessionIDs)
        let prompt = SliceClip.text(
            TerminalLaunch.workOnTargetPrompt(targetID: id, vocabulary: .current), limit: 1000
        )
        let lastStatus = facts.lastStatus[id]
        return Payload(
            id: id, workbenchID: workbenchID, parentID: parentID,
            text: text.text, textClipped: text.clipped,
            intent: intent.text, intentClipped: intent.clipped,
            status: target.status, priority: target.priority, progress: target.progress,
            branch: branch.text, branchClipped: branch.clipped,
            pr: pr.text, prClipped: pr.clipped,
            archived: archived,
            childrenCount: node.children.count,
            openComments: node.openComments,
            unreadForOwner: node.unreadForOwner,
            openAsks: facts.openAsks[id] ?? 0,
            sessionIDs: sessions.items, sessionIDsMore: sessions.more,
            lastStatusAt: lastStatus.flatMap { SliceDate.parse($0.at) },
            lastStatusActor: lastStatus?.actor,
            workOnPrompt: prompt.text, workOnPromptClipped: prompt.clipped,
            createdAt: SliceDate.parseOrEpoch(target.createdAt),
            updatedAt: SliceDate.parseOrEpoch(target.updatedAt)
        )
    }
}

/// Per-target facts the board does not carry, read once for all boards.
private struct TargetFacts {
    /// target id → open `owner_asks` filed on it.
    var openAsks: [Int64: Int] = [:]
    /// target id → `claude` sessions with this `target_id` or linked through
    /// `terminal_session_targets`, the most recently active first.
    var sessions: [Int64: [Int64]] = [:]
    /// target id → its newest `target_status_history` row.
    var lastStatus: [Int64: (at: String, actor: String)] = [:]

    static func load(_ db: Database) throws -> Self {
        var facts = Self()
        for row in try Row.fetchAll(db, sql: """
            SELECT target_id, COUNT(*) AS n FROM owner_asks
            WHERE status = 'open' AND target_id IS NOT NULL GROUP BY target_id
            """) {
            facts.openAsks[row["target_id"]] = row["n"]
        }
        for row in try Row.fetchAll(db, sql: """
            SELECT link.target_id, s.id AS session_id
            FROM (
                SELECT id AS session_id, target_id FROM terminal_sessions WHERE target_id IS NOT NULL
                UNION
                SELECT session_id, target_id FROM terminal_session_targets
            ) AS link
            JOIN terminal_sessions s ON s.id = link.session_id
            WHERE s.kind = 'claude' AND s.project_id IS NOT NULL
            ORDER BY link.target_id, s.last_active_at DESC, s.id DESC
            """) {
            facts.sessions[row["target_id"], default: []].append(row["session_id"])
        }
        for row in try Row.fetchAll(db, sql: """
            SELECT h.target_id, h.changed_at, h.actor FROM target_status_history h
            JOIN (SELECT target_id, MAX(id) AS id FROM target_status_history GROUP BY target_id) newest
              ON newest.id = h.id
            """) {
            facts.lastStatus[row["target_id"]] = (row["changed_at"], row["actor"])
        }
        return facts
    }
}
