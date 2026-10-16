import WatchtowerKit
import XCTest
@testable import WatchtowerMobile

/// The board row's and the detail's status label: the Mac's column title
/// when the workbench defines columns (board #267), else the status label.
final class BoardModelTests: XCTestCase {
    private let now = Date()

    private func snapshot(column: String?) throws -> WorkbenchReplicaSnapshot {
        var snapshot = try demoSnapshot(now: now)
        let source = try XCTUnwrap(snapshot.targets.first { $0.id == 416 })
        var json: [String: Any] = [
            "id": source.id, "workbench_id": source.workbenchID, "text": source.text, "text_clipped": false,
            "intent": "", "status": "in_progress", "priority": "medium", "progress": 0.0, "branch": "", "pr": "",
            "archived": false, "children_count": 0, "open_comments": 0, "unread_for_owner": 0, "open_asks": 0,
            "session_ids": [Int64](), "work_on_prompt": "",
            "created_at": 1_699_990_000, "updated_at": 1_699_990_000
        ]
        if let column { json["column"] = column }
        snapshot.targets = [try mirror(WorkbenchTarget.self, json)]
        return snapshot
    }

    func testRowShowsColumnTitle() throws {
        let withColumn = try snapshot(column: "QA")
        let target = try XCTUnwrap(withColumn.targets.first)
        XCTAssertEqual(BoardRowModel(target, snapshot: withColumn).statusText, "QA")
        let detail = try XCTUnwrap(BoardTargetDetailModel(targetID: target.id, snapshot: withColumn, now: now))
        XCTAssertEqual(detail.statusLabel, "QA")

        let without = try snapshot(column: nil)
        let plain = try XCTUnwrap(without.targets.first)
        XCTAssertEqual(BoardRowModel(plain, snapshot: without).statusText, "In progress")
        XCTAssertEqual(try XCTUnwrap(BoardTargetDetailModel(targetID: plain.id, snapshot: without, now: now)).statusLabel, "In progress")
    }
}
