import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

/// Parent progress is a dual path: Go's `recomputeParentProgressOn`
/// (internal/db/targets.go) and `TargetQueries.recomputeParentProgress` both
/// write it. `internal/db/testdata/target_progress_cases.json` is replayed by
/// Go's `TestRecomputeParentProgress_SharedFixture` and by this suite, so the
/// two writers must land on identical rows — progress values and which rows
/// got their `updated_at` bumped.
final class TargetProgressFixtureTests: XCTestCase {

    private struct Case: Decodable {
        struct Row: Decodable {
            let id: Int
            let parent_id: Int?
            let status: String
            let progress: Double
        }
        struct Operation: Decodable {
            let kind: String
            let id: Int?
            let parent_id: Int?
            let status: String?
        }
        struct Want: Decodable {
            let progress: [String: Double]
            let touched: [Int]
        }
        let name: String
        let targets: [Row]
        let op: Operation
        let want: Want
    }

    private static let sentinel = "2000-01-01T00:00:00Z"

    private static func cases() throws -> [Case] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("internal/db/testdata/target_progress_cases.json")
        return try JSONDecoder().decode([Case].self, from: Data(contentsOf: url))
    }

    private static func seed(_ db: Database, _ rows: [Case.Row]) throws {
        for row in rows {
            try db.execute(
                sql: """
                    INSERT INTO targets (id, text, period_start, period_end, status, progress)
                    VALUES (?, 'fixture', '2026-01-01', '2026-01-01', ?, ?)
                    """,
                arguments: [row.id, row.status, row.progress]
            )
        }
        // Parents are wired in a second pass so a cycle can be expressed.
        for row in rows {
            guard let parent = row.parent_id else { continue }
            try db.execute(sql: "UPDATE targets SET parent_id = ? WHERE id = ?", arguments: [parent, row.id])
        }
        try db.execute(sql: "UPDATE targets SET updated_at = ?", arguments: [sentinel])
    }

    private static func apply(_ db: Database, _ op: Case.Operation) throws {
        switch op.kind {
        case "recompute":
            try TargetQueries.recomputeParentProgress(db, parentID: try XCTUnwrap(op.id))
        case "status":
            try TargetQueries.updateStatus(db, id: try XCTUnwrap(op.id), status: try XCTUnwrap(op.status))
        case "delete":
            try TargetQueries.delete(db, id: try XCTUnwrap(op.id))
        case "reparent":
            try TargetQueries.updateParent(db, id: try XCTUnwrap(op.id), parentID: try XCTUnwrap(op.parent_id))
        case "create":
            try TargetQueries.create(
                db,
                text: "created",
                periodStart: "2026-01-01",
                periodEnd: "2026-01-01",
                parentId: try XCTUnwrap(op.parent_id),
                status: try XCTUnwrap(op.status)
            )
        default:
            XCTFail("unknown op kind \(op.kind)")
        }
    }

    func testSharedFixtureMatchesGo() throws {
        let cases = try Self.cases()
        XCTAssertGreaterThanOrEqual(cases.count, 8, "fixture must not silently shrink")

        for fixture in cases {
            let queue = try TestDatabase.create()
            try queue.write { db in
                try Self.seed(db, fixture.targets)
                try Self.apply(db, fixture.op)
            }
            let rows = try queue.read { db in
                try Row.fetchAll(db, sql: "SELECT id, progress, updated_at FROM targets ORDER BY id")
            }

            var got: [String: Double] = [:]
            var touched: [Int] = []
            for row in rows {
                let id: Int = row["id"]
                got[String(id)] = row["progress"]
                if (row["updated_at"] as String) != Self.sentinel { touched.append(id) }
            }

            XCTAssertEqual(Set(got.keys), Set(fixture.want.progress.keys), fixture.name)
            for (id, want) in fixture.want.progress {
                XCTAssertEqual(got[id] ?? -1, want, accuracy: 1e-9, "\(fixture.name): target \(id)")
            }
            XCTAssertEqual(touched, fixture.want.touched.sorted(), fixture.name)
        }
    }
}
