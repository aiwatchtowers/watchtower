import XCTest
@testable import WatchtowerCore

final class ScreenContextTests: XCTestCase {
    func testBlockOmitsMissingLines() {
        let block = ScreenContext(tab: "Inbox").block
        XCTAssertFalse(block.contains("Status:"))
        XCTAssertFalse(block.contains("Selected:"))
    }

    func testBlockFormat() {
        let screen = ScreenContext(tab: "Digests", status: "Waiting for sync", selected: "Weekly digest")
        XCTAssertEqual(screen.block, """
        === CURRENT SCREEN ===
        Tab: Digests
        Status: Waiting for sync
        Selected: Weekly digest
        ===
        """)
        XCTAssertEqual(ScreenContext(tab: "Inbox").block, "=== CURRENT SCREEN ===\nTab: Inbox\n===")
    }
}
