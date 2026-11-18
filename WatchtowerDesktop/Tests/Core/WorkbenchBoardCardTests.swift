import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

final class WorkbenchBoardCardTests: XCTestCase {
    private var queue: DatabaseQueue!

    override func setUpWithError() throws {
        queue = try TestDatabase.create()
    }

    // Real Target rows through the DB, so the fixture never drifts from
    // Target's own row decoding.
    private func target(
        _ id: Int,
        _ text: String = "Task",
        status: String = "todo",
        priority: String = "medium",
        progress: Double = 0
    ) throws -> Target {
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO targets (id, text, level, custom_label, period_start, period_end,
                        status, priority, progress, source_type, ownership)
                    VALUES (?, ?, 'custom', 'project', '2026-09-29', '2026-09-29', ?, ?, ?, 'chat', 'mine')
                    """,
                arguments: [id, text, status, priority, progress]
            )
            return try XCTUnwrap(TargetQueries.fetchByID(db, id: id))
        }
    }

    private func node(_ t: Target, _ children: [WorkbenchBoardNode] = []) -> WorkbenchBoardNode {
        WorkbenchBoardNode(target: t, children: children, openComments: 0, unreadForOwner: 0)
    }

    // MARK: - Order (Go boardSiblingOrder)

    func testOrderIsPriorityThenStatusThenID() throws {
        let targets = [
            try target(1, status: "in_progress", priority: "low"),
            try target(2, status: "done", priority: "high"),
            try target(3, status: "todo", priority: "high"),
            try target(4, status: "blocked", priority: "medium"),
            try target(5, status: "in_progress", priority: "medium"),
            try target(6, status: "dismissed", priority: "high"),
            try target(7, status: "todo", priority: "high")
        ]
        XCTAssertEqual(WorkbenchBoardOrder.sorted(targets.shuffled()).map(\.id), [3, 7, 2, 6, 5, 4, 1])
    }

    // Go's boardSiblingOrder has the same arms except in_review, which it gains
    // with the status itself; keep the two in step.
    func testRankTables() {
        XCTAssertEqual(["high", "medium", "low", "bogus"].map(WorkbenchBoardOrder.priorityRank), [0, 1, 2, 2])
        XCTAssertEqual(
            ["in_progress", "in_review", "blocked", "todo", "done", "dismissed", "snoozed"]
                .map(WorkbenchBoardOrder.statusRank),
            [0, 1, 2, 3, 4, 5, 5]
        )
    }

    // MARK: - Card

    func testParentCountsDoneChildrenAndIgnoresDismissed() throws {
        let card = WorkbenchBoardCard(node(try target(1, "Feature"), [
            node(try target(2, status: "done")),
            node(try target(3, status: "in_progress")),
            node(try target(4, status: "dismissed"))
        ]))
        XCTAssertEqual(card.children, .init(done: 1, total: 2))
        XCTAssertEqual(card.children?.fraction, 0.5)
        XCTAssertNil(card.leafProgress, "a parent shows its children, not its own progress")
    }

    func testParentWithOnlyDismissedChildrenShowsNoChildProgress() throws {
        let card = WorkbenchBoardCard(node(try target(1), [node(try target(2, status: "dismissed"))]))
        XCTAssertNil(card.children, "no 0/0 counter or empty bar")
        XCTAssertNil(card.leafProgress)
    }

    func testLeafShowsOnlyPartialProgress() throws {
        XCTAssertEqual(WorkbenchBoardCard(node(try target(1, progress: 0.4))).leafProgress, 0.4)
        XCTAssertNil(WorkbenchBoardCard(node(try target(2, progress: 0))).leafProgress)
        XCTAssertNil(WorkbenchBoardCard(node(try target(3, progress: 1))).leafProgress)
        XCTAssertNil(WorkbenchBoardCard(node(try target(4))).children)
    }

    func testClosedAndDoneFlags() throws {
        let done = WorkbenchBoardCard(node(try target(1, status: "done")))
        let dismissed = WorkbenchBoardCard(node(try target(2, status: "dismissed")))
        let blocked = WorkbenchBoardCard(node(try target(3, status: "blocked")))
        XCTAssertEqual([done.isClosed, done.isDone], [true, true])
        XCTAssertEqual([dismissed.isClosed, dismissed.isDone], [true, false])
        XCTAssertEqual([blocked.isClosed, blocked.isDone], [false, false])
    }

    func testTitleIsFirstNonBlankLine() {
        XCTAssertEqual(WorkbenchBoardCard.title("\n  \n  Ship it  \nDetails"), "Ship it")
        XCTAssertEqual(WorkbenchBoardCard.title("One"), "One")
        XCTAssertEqual(WorkbenchBoardCard.title(" \n "), "")
    }

    func testStatusLabels() {
        XCTAssertEqual(
            WorkbenchBoardCard.editableStatuses.map(WorkbenchBoardCard.statusLabel),
            ["To Do", "In Progress", "In Review", "Blocked", "Done", "Dismissed"]
        )
        XCTAssertEqual(WorkbenchBoardCard.statusLabel("in_review"), "In Review")
        XCTAssertEqual(WorkbenchBoardCard.statusLabel("waiting_on_vendor"), "waiting_on_vendor", "unknown = raw text")
    }

    /// A real row with its status replaced: the targets CHECK does not admit
    /// `in_review` (or an unknown value) yet, but a newer CLI may write one.
    private func target(_ id: Int, rawStatus: String) throws -> Target {
        _ = try target(id)
        let row = try queue.read { db in
            try XCTUnwrap(Row.fetchOne(db, sql: "SELECT * FROM targets WHERE id = ?", arguments: [id]))
        }
        var columns: [String: DatabaseValue] = [:]
        for (name, value) in row { columns[name] = value }
        columns["status"] = rawStatus.databaseValue
        return Target(row: Row(columns))
    }

    func testStatusColoursIconsAndLabelsKnowInReview() throws {
        let review = try target(1, rawStatus: "in_review")
        XCTAssertEqual(review.statusColor, "teal")
        XCTAssertEqual(review.statusIcon, "eye.circle")
        let unknown = try target(2, rawStatus: "waiting_on_vendor")
        XCTAssertEqual(unknown.statusColor, "secondary", "unknown status = neutral")
        XCTAssertEqual(WorkbenchBoardCard.statusLabel(unknown.status), "waiting_on_vendor")
    }

    // MARK: - Folder chip (spec 2026-11-18 §6.10)

    private func folder(_ id: Int64, _ name: String, removed: Bool = false) -> WorkbenchFolder {
        WorkbenchFolder(
            id: id, workbenchID: 1, folderPath: "/tmp/\(name)", position: Int(id),
            removedAt: removed ? "2026-11-01T00:00:00Z" : nil, name: name
        )
    }

    /// A target of the bench, in `folderID` (nil = the home folder).
    private func target(_ id: Int, folderID: Int64?) throws -> Target {
        _ = try target(id)
        return try queue.write { db in
            try db.execute(sql: "UPDATE targets SET workbench_folder_id = ? WHERE id = ?", arguments: [folderID, id])
            return try XCTUnwrap(TargetQueries.fetchByID(db, id: id))
        }
    }

    private func seedBench() throws {
        try queue.write { db in
            try db.execute(sql: "INSERT INTO projects (id, name, folder_path) VALUES (1, 'acme', '/tmp/app')")
            for (id, name, position) in [(1, "app", 0), (2, "hub", 1)] {
                try db.execute(
                    sql: """
                        INSERT INTO workbench_folders (id, workbench_id, folder_path, position, added_by, name)
                        VALUES (?, 1, ?, ?, 'owner', ?)
                        """,
                    arguments: [id, "/tmp/\(name)", position, name]
                )
            }
        }
    }

    func testFolderChipOnlyWithMoreThanOneFolder() throws {
        try seedBench()
        let hub = try target(1, folderID: 2)
        let home = try target(2, folderID: nil)
        let two = BenchFolders(folders: [folder(1, "app"), folder(2, "hub")], homeID: 1)
        XCTAssertEqual(WorkbenchBoardCard(node(hub), folders: two).folderChip, .folder("hub"))
        XCTAssertEqual(WorkbenchBoardCard(node(hub), folders: two).folderChip?.text, "hub")
        XCTAssertEqual(WorkbenchBoardCard(node(home), folders: two).folderChip, .folder("app"), "no folder stored = home")

        let one = BenchFolders(folders: [folder(1, "app")], homeID: 1)
        XCTAssertNil(WorkbenchBoardCard(node(home), folders: one).folderChip, "a one-folder bench looks as before")
        let oneLiveOfTwo = BenchFolders(folders: [folder(1, "app"), folder(2, "hub", removed: true)], homeID: 1)
        XCTAssertNil(WorkbenchBoardCard(node(home), folders: oneLiveOfTwo).folderChip)
        XCTAssertNil(WorkbenchBoardCard(node(home)).folderChip, "folders not read yet")
        let stranger = try target(3, folderID: nil)
        XCTAssertNil(WorkbenchBoardCard(node(stranger), folders: BenchFolders()).folderChip, "no home row to name")
    }

    func testRemovedFolderShowsFolderRemoved() throws {
        try seedBench()
        let hub = try target(1, folderID: 2)
        let two = BenchFolders(folders: [folder(1, "app"), folder(2, "hub", removed: true), folder(3, "site")], homeID: 1)
        let chip = WorkbenchBoardCard(node(hub), folders: two).folderChip
        XCTAssertEqual(chip, .removed)
        XCTAssertEqual(chip?.text, "· folder removed")
        XCTAssertEqual(WorkbenchBoardCard.folderRemovedText, "· folder removed")
        // Said even once the bench is down to one live folder: the work cannot be checked.
        let one = BenchFolders(folders: [folder(1, "app"), folder(2, "hub", removed: true)], homeID: 1)
        XCTAssertEqual(WorkbenchBoardCard(node(hub), folders: one).folderChip, .removed)
    }

    func testFolderMenuTitles() {
        XCTAssertEqual(WorkbenchBoardCard.folderMenuTitle(folder(1, "app")), "app")
        XCTAssertEqual(WorkbenchBoardCard.folderMenuTitle(folder(2, "hub", removed: true)), "Folder removed")
        XCTAssertEqual(WorkbenchBoardCard.folderMenuTitle(nil), "Folder")
    }

    func testOwnerFolderEditWritesTheColumn() throws {
        try seedBench()
        _ = try target(1)
        try queue.write { db in
            try db.execute(sql: "UPDATE targets SET project_id = 1 WHERE id = 1")
            try TargetQueries.setFolder(db, targetID: 1, folderID: 2)
        }
        XCTAssertEqual(try queue.read { try TargetQueries.fetchByID($0, id: 1) }?.workbenchFolderID, 2)

        // Back to the home folder: nil.
        try queue.write { try TargetQueries.setFolder($0, targetID: 1, folderID: nil) }
        XCTAssertNil(try queue.read { try TargetQueries.fetchByID($0, id: 1) }?.workbenchFolderID)

        // Last write wins with the CLI (PROJ-07 note): a later write over the same column stands.
        try queue.write { db in
            try db.execute(sql: "UPDATE targets SET workbench_folder_id = 1 WHERE id = 1")
            try TargetQueries.setFolder(db, targetID: 1, folderID: 2)
        }
        XCTAssertEqual(try queue.read { try TargetQueries.fetchByID($0, id: 1) }?.workbenchFolderID, 2)
    }

    func testOwnerFolderEditRefusesAForeignRemovedOrUnboardedTarget() throws {
        try seedBench()
        _ = try target(1)
        try queue.write { db in
            try db.execute(sql: "UPDATE targets SET project_id = 1 WHERE id = 1")
            try db.execute(sql: "INSERT INTO projects (id, name, folder_path) VALUES (2, 'other', '/tmp/other')")
            try db.execute(sql: """
                INSERT INTO workbench_folders (id, workbench_id, folder_path, position, added_by, name)
                VALUES (3, 2, '/tmp/other', 0, 'owner', 'other')
                """)
            try db.execute(sql: "UPDATE workbench_folders SET removed_at = '2026-11-01T00:00:00Z' WHERE id = 2")
        }
        XCTAssertThrowsError(try queue.write { try TargetQueries.setFolder($0, targetID: 1, folderID: 3) }) {
            XCTAssertEqual($0 as? TargetFolderError, .notAFolderOfTheBench(3))
        }
        XCTAssertThrowsError(try queue.write { try TargetQueries.setFolder($0, targetID: 1, folderID: 2) }) {
            XCTAssertEqual($0 as? TargetFolderError, .notAFolderOfTheBench(2))
        }
        _ = try target(5)
        XCTAssertThrowsError(try queue.write { try TargetQueries.setFolder($0, targetID: 5, folderID: nil) }) {
            XCTAssertEqual($0 as? TargetFolderError, .notOnABoard(5))
        }
        XCTAssertThrowsError(try queue.write { try TargetQueries.setFolder($0, targetID: 99, folderID: nil) }) {
            XCTAssertEqual($0 as? TargetNotFoundError, TargetNotFoundError(id: 99))
        }
        XCTAssertEqual(
            TargetFolderError.notOnABoard(5).errorDescription, "target #5 is not on a workbench board"
        )
        XCTAssertEqual(
            TargetFolderError.notAFolderOfTheBench(3).errorDescription, "that folder is not on this workbench"
        )
    }
}
