import GRDB
import WatchtowerTestSupport
import XCTest
@testable import WatchtowerCore

/// `owner_asks` rows after 00196: the `folder` kind with its suggestion
/// payload and `doc_folder_id`. A kind this build does not know is a third
/// state — the row is named as unreadable beside the list — never a crash
/// and never shown as another kind (review-rules, Error handling).
final class OwnerAskDecodingTests: XCTestCase {
    private var db: DatabaseQueue!
    private var bench: Int64 = 0

    override func setUpWithError() throws {
        db = try TestDatabase.create()
        bench = try db.write { try TestDatabase.insertWorkbench($0) }
    }

    private func open() throws -> OwnerAskRows {
        try db.read { try OwnerAskQueries.openAsks($0, projectID: self.bench) }
    }

    func testOldOwnerAskKindsStillDecode() throws {
        try db.write { db in
            try TestDatabase.insertOwnerAsk(db, projectID: self.bench, kind: "review", title: "Spec", docPath: "docs/spec.md")
            try TestDatabase.insertOwnerAsk(db, projectID: self.bench, kind: "check", title: "Run it",
                                            payload: #"{"checklist":[{"text":"Open the app"}]}"#)
            try TestDatabase.insertOwnerAsk(db, projectID: self.bench, kind: "question")
        }
        let rows = try open()
        XCTAssertNil(rows.problem)
        XCTAssertEqual(rows.asks.map(\.kind), [.review, .check, .question])
        let review = rows.asks[0]
        XCTAssertEqual(review.docPath, "docs/spec.md")
        XCTAssertNil(review.docFolderID, "an old review resolves in the home folder")
        XCTAssertTrue(rows.asks.allSatisfy { $0.folderSuggestion == nil })
    }

    func testFolderAskDecodes() throws {
        let payload = #"{"path":"/tmp/hub","repo_root":"/tmp/hub","touches":3,"why":"the API lives there"}"#
        let other = #"{"path":"/tmp/site","repo_root":"/tmp/site","touches":4,"why":"","other_bench":{"id":9,"name":"web"}}"#
        try db.write { db in
            try TestDatabase.insertOwnerAsk(db, projectID: self.bench, kind: "folder", title: "Put hub on the bench?", payload: payload)
            try TestDatabase.insertOwnerAsk(db, projectID: self.bench, kind: "folder", title: "Put site on the bench?", payload: other)
        }
        let rows = try open()
        XCTAssertNil(rows.problem)
        XCTAssertEqual(rows.asks.map(\.kind), [.folder, .folder])
        XCTAssertEqual(rows.asks[0].folderSuggestion,
                       FolderSuggestionPayload(path: "/tmp/hub", repoRoot: "/tmp/hub", touches: 3, why: "the API lives there"))
        XCTAssertEqual(rows.asks[1].folderSuggestion?.otherBench, FolderSuggestionPayload.OtherBench(id: 9, name: "web"))
        XCTAssertEqual(rows.asks[1].payload, OwnerAskPayload(), "no focus, questions or checklist")
    }

    /// A folder ask without its folder is a broken row: named, the others shown.
    func testAFolderAskWithoutAPathIsUnreadable() throws {
        let broken = try db.write { db -> Int64 in
            try TestDatabase.insertOwnerAsk(db, projectID: self.bench, kind: "question")
            return try TestDatabase.insertOwnerAsk(db, projectID: self.bench, kind: "folder", payload: #"{"why":"x"}"#)
        }
        let rows = try open()
        XCTAssertEqual(rows.asks.map(\.kind), [.question])
        XCTAssertEqual(rows.unreadableIDs, [broken])
    }

    func testAnUnknownKindIsNamedNotShown() throws {
        let rows = try db.read { db in
            try OwnerAskRows.fetch(db, sql: """
                SELECT 7 AS id, 1 AS project_id, 'merge' AS kind, 'quick' AS level, 'agent' AS origin,
                       'open' AS status, '{}' AS payload
                UNION ALL
                SELECT 8, 1, 'question', 'quick', 'agent', 'open', '{}'
                """, arguments: [])
        }
        XCTAssertEqual(rows.asks.map(\.id), [8])
        XCTAssertEqual(rows.unreadableIDs, [7])
        XCTAssertEqual(rows.problem, "1 ask could not be read (#7).")
    }

    func testADocFolderIsRead() throws {
        let hub = try db.write { db -> Int64 in
            try db.execute(sql: """
                INSERT INTO workbench_folders (workbench_id, folder_path, position, added_by, name)
                VALUES (?, '/tmp/hub', 1, 'owner', 'hub')
                """, arguments: [self.bench])
            let hub = db.lastInsertedRowID
            let ask = try TestDatabase.insertOwnerAsk(db, projectID: self.bench, kind: "review", docPath: "docs/plan.md")
            try db.execute(sql: "UPDATE owner_asks SET doc_folder_id = ? WHERE id = ?", arguments: [hub, ask])
            return hub
        }
        let ask = try XCTUnwrap(try open().asks.first)
        XCTAssertEqual(ask.docFolderID, hub)
        let folders = try db.read { try WorkbenchFolderQueries.benchFolders($0, workbenchID: self.bench) }
        XCTAssertEqual(folders.displayPath(ask.docPath, folderID: ask.docFolderID), "hub/docs/plan.md")
    }

    /// The folder kind's labels: no plain answer actions (its card answers),
    /// the Put on the Bench icon, the card's primary button as next step.
    func testFolderKindPresentation() {
        XCTAssertEqual(OwnerAskPresentation.answerActions(for: .folder), [])
        XCTAssertEqual(OwnerAskPresentation.askKindIcon(.folder), "plus.rectangle.on.folder")
        XCTAssertEqual(OwnerAskPresentation.askKindLabel(.folder), "Folder")
        XCTAssertEqual(OwnerAskPresentation.folderNextStep, "Put on Bench")
    }
}
