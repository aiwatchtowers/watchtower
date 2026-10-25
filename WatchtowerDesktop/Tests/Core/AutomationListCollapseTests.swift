import XCTest
@testable import WatchtowerCore

final class AutomationListCollapseTests: XCTestCase {
    func testCollapseSearchExpandsWithoutChangingStore() {
        var collapse = AutomationListCollapse()
        collapse.toggle("personal")
        XCTAssertFalse(collapse.isExpanded("personal", searching: false, hasMatch: true))
        XCTAssertTrue(collapse.isExpanded("personal", searching: true, hasMatch: true))
        XCTAssertFalse(collapse.isExpanded("personal", searching: true, hasMatch: false))
        XCTAssertEqual(collapse.collapsed, ["personal"])
        collapse.toggle("personal")
        XCTAssertTrue(collapse.isExpanded("personal", searching: false, hasMatch: false))
    }

    func testRevealOpensCollapsedGroup() {
        var collapse = AutomationListCollapse(collapsed: ["builtin", "personal"])
        collapse.reveal("personal")
        XCTAssertEqual(collapse.collapsed, ["builtin"])
        collapse.reveal("personal")
        XCTAssertEqual(collapse.collapsed, ["builtin"])
    }
}
