import Foundation
import GRDB

/// Migration 00183's seed rows, which the generated test schema (DDL only)
/// lacks, plus owner folders and routes the tests write directly. The
/// Desktop itself never writes these tables; only tests do.
enum InboxFolderFixtures {
    struct Seed {
        let root: Int64
        let approvals: Int64
    }

    /// The root (`inbox`), Needs approval (`needs-approval`) and revision 1.
    @discardableResult
    static func seed(_ db: Database, revision: Int64 = 1) throws -> Seed {
        try db.execute(sql: """
            INSERT INTO inbox_folders (kind, parent_id, slug, title, position) VALUES ('root', NULL, 'inbox', 'Inbox', 0)
            """)
        let root = db.lastInsertedRowID
        try db.execute(sql: """
            INSERT INTO inbox_folders (kind, parent_id, slug, title, position)
            VALUES ('approvals', ?, 'needs-approval', 'Needs approval', 0)
            """, arguments: [root])
        let approvals = db.lastInsertedRowID
        try db.execute(sql: "INSERT INTO inbox_folder_state (id, revision) VALUES (1, ?)", arguments: [revision])
        return Seed(root: root, approvals: approvals)
    }

    @discardableResult
    static func folder(
        _ db: Database,
        parent: Int64,
        slug: String,
        title: String? = nil,
        position: Int,
        hidden: Bool = false,
        icon: String = ""
    ) throws -> Int64 {
        try db.execute(sql: """
            INSERT INTO inbox_folders (kind, parent_id, slug, title, icon, position, hidden)
            VALUES ('owner', ?, ?, ?, ?, ?, ?)
            """, arguments: [parent, slug, title ?? slug.capitalized, icon, position, hidden])
        return db.lastInsertedRowID
    }

    static func route(_ db: Database, automation: Int64, folder: Int64) throws {
        try db.execute(sql: "INSERT INTO inbox_folder_routes (automation_id, folder_id) VALUES (?, ?)",
                       arguments: [automation, folder])
    }

    /// A v1 block document with one list whose rows carry `refs`.
    static func listDocument(_ refs: [(kind: String, id: Int64)]) -> String {
        let rows = refs.map { #"{"title":"row \#($0.id)","ref":{"kind":"\#($0.kind)","id":\#($0.id)}}"# }
        return #"{"v":1,"blocks":[{"type":"list","rows":[\#(rows.joined(separator: ","))]}]}"#
    }
}
