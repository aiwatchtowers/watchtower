import XCTest
import SwiftUI
import GRDB
import ViewInspector
import WatchtowerCore
import WatchtowerTestSupport
@testable import WatchtowerDesktop

/// Board #370: a parent card's collapse control is its whole left strip, so
/// a click there folds the sub-tasks instead of falling through to the list's
/// selection (which opens the card).
@MainActor
final class WorkbenchBoardCardViewTests: XCTestCase {
    /// A feature with one task, as the board lists them: rows[0] is the
    /// parent, rows[1] the leaf.
    private func rows() throws -> [WorkbenchBoardRow] {
        let queue = try TestDatabase.create()
        let roots = try queue.write { db in
            try db.execute(
                sql: "INSERT INTO projects (name, folder_path) VALUES ('acme', ?)",
                arguments: ["/tmp/acme-\(UUID().uuidString)"]
            )
            let pid = db.lastInsertedRowID
            for (text, parent) in [("Feature", nil), ("Task", 1)] as [(String, Int64?)] {
                try db.execute(
                    sql: """
                        INSERT INTO targets (text, level, custom_label, period_start, period_end,
                            parent_id, status, source_type, ownership, project_id)
                        VALUES (?, 'custom', 'project', '2026-09-29', '2026-09-29', ?, 'todo', 'chat', 'mine', ?)
                        """,
                    arguments: [text, parent, pid]
                )
            }
            return try WorkbenchQueries.board(db, projectID: pid)
        }
        let rows = WorkbenchBoardOutline.rows(roots, collapsed: [], showDone: true)
        XCTAssertEqual(rows.map(\.hasChildren), [true, false])
        return rows
    }

    func testParentChevronZoneIsTheFullHeightLeftStripAndToggles() throws {
        var toggles = 0
        let view = WorkbenchBoardCardView(row: try rows()[0], isSelected: false, isCollapsed: true) {
            toggles += 1
        }

        let button = try view.inspect()
            .find(viewWithAccessibilityIdentifier: WorkbenchBoardChevron.accessibilityID)
            .button()
        let zone = try button.labelView().image()
        XCTAssertGreaterThanOrEqual(try zone.fixedWidth(), 28)
        let frame = try zone.flexFrame()
        XCTAssertGreaterThanOrEqual(frame.minHeight, 28)
        XCTAssertEqual(frame.maxHeight, .infinity, "the zone spans the card's whole height")
        XCTAssertNoThrow(try zone.contentShape(Rectangle.self), "the whole zone is hittable, not just the glyph")

        XCTAssertEqual(try button.accessibilityLabel().string(), "Show sub-tasks")
        XCTAssertEqual(try button.accessibilityValue().string(), "Collapsed")

        try button.tap()
        XCTAssertEqual(toggles, 1)
    }

    func testLeafCardHasNoChevronButton() throws {
        let view = WorkbenchBoardCardView(row: try rows()[1], isSelected: false, isCollapsed: false) {}

        XCTAssertThrowsError(
            try view.inspect().find(viewWithAccessibilityIdentifier: WorkbenchBoardChevron.accessibilityID)
        )
    }
}
