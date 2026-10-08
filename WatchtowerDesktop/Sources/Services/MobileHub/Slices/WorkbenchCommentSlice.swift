import Foundation
import GRDB
import WatchtowerCore
import WatchtowerSync

/// The `workbench_comment` slice (mobile POC spec §4.4), record name
/// `workbench_comment-<project_comments.id>`: comments on published board
/// targets (`WorkbenchTargetWindow`, published workbenches only), the newest
/// 200 per target. A reply that names only its parent counts toward its
/// root's target. The phone never marks comments read.
///
/// Wire shape: the Kit mirror `WatchtowerKit.WorkbenchComment`.
struct WorkbenchCommentSlice: SliceSource {
    let kind = SliceKind.workbenchComment

    static let maxPerTarget = 200

    let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    struct Payload: Encodable, Equatable {
        let id: Int64
        let workbenchID: Int64
        let targetID: Int64?
        let parentID: Int64?
        let author: String
        let agentLabel: String
        let agentLabelClipped: Bool? // swiftlint:disable:this discouraged_optional_boolean
        let body: String
        let bodyClipped: Bool? // swiftlint:disable:this discouraged_optional_boolean
        let status: String
        let createdAt: Date
        let read: Bool

        enum CodingKeys: String, CodingKey {
            case id
            case workbenchID = "workbench_id"
            case targetID = "target_id"
            case parentID = "parent_id"
            case author, agentLabel, agentLabelClipped, body, bodyClipped, status, createdAt, read
        }
    }

    func records(_ db: Database) throws -> [SliceRecord] {
        let workbenches = Set(try WorkbenchSlice.publishedWorkbenches(db).map(\.id))
        guard !workbenches.isEmpty else { return [] }
        let published = try WorkbenchTargetWindow.load(db, now: now()).published
        let rows = try Row.fetchAll(db, sql: """
            SELECT * FROM (
                SELECT c.id, c.project_id, c.target_id, c.parent_id, c.author, c.agent_label, c.body, c.status,
                       c.created_at, c.read_at, COALESCE(c.target_id, root.target_id) AS board_target,
                       ROW_NUMBER() OVER (
                           PARTITION BY COALESCE(c.target_id, root.target_id)
                           ORDER BY c.created_at DESC, c.id DESC
                       ) AS rank
                FROM project_comments c
                LEFT JOIN project_comments root ON root.id = c.parent_id
            )
            WHERE board_target IS NOT NULL AND rank <= ?
            ORDER BY id
            """, arguments: [Self.maxPerTarget])
        let encoder = RelayCoder.makeEncoder()
        let stamp = now()
        return try rows.compactMap { row in
            let project: Int64 = row["project_id"]
            let boardTarget: Int64 = row["board_target"]
            guard workbenches.contains(project), published[boardTarget] != nil else { return nil }
            let id: Int64 = row["id"]
            let label = SliceClip.text(row["agent_label"] ?? "", limit: 60)
            let body = SliceClip.text(row["body"] ?? "", limit: 4000)
            let readAt: String = row["read_at"] ?? ""
            let payload = Payload(
                id: id, workbenchID: project, targetID: row["target_id"], parentID: row["parent_id"],
                author: row["author"], agentLabel: label.text, agentLabelClipped: label.clipped,
                body: body.text, bodyClipped: body.clipped, status: row["status"],
                createdAt: SliceDate.parseOrEpoch(row["created_at"] ?? ""), read: !readAt.isEmpty
            )
            return SliceRecord(kind: kind, id: String(id), modifiedAt: stamp, payload: try encoder.encode(payload))
        }
    }
}
