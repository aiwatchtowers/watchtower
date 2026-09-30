import XCTest
@testable import WatchtowerCore

final class WorkspaceLayoutTests: XCTestCase {
    private func split() -> WorkspaceLayout {
        var l = WorkspaceLayout.default
        l.split(with: .session(1))
        return l
    }

    func testExpandAndRestore() {
        var l = split()
        l.toggleExpand(.board)
        XCTAssertEqual(l.visiblePanes, [.board])
        l.toggleExpand(.board)
        XCTAssertEqual(l.visiblePanes, [.board, .session(1)])
    }

    func testSplitWithPrimaryIsNoOp() {
        var l = WorkspaceLayout.default
        l.split(with: .board)
        XCTAssertEqual(l, .default)
    }

    func testUnsplitKeepsPrimary() {
        var l = split()
        l.toggleExpand(.session(1))
        l.unsplit()
        XCTAssertEqual(l.primary, .board)
        XCTAssertNil(l.secondary)
        XCTAssertNil(l.expanded)
    }

    func testShowSingleReplacesPrimary() {
        var l = WorkspaceLayout.default
        l.show(.documents)
        XCTAssertEqual(l.primary, .documents)
        XCTAssertFalse(l.isSplit)
    }

    func testShowSplitReplacesSecondary() {
        var l = split()
        l.show(.documents)
        XCTAssertEqual(l.primary, .board)
        XCTAssertEqual(l.secondary, .documents)
    }

    func testShowVisibleIsNoOp() {
        var l = split()
        let before = l
        l.show(.session(1))
        l.show(.board)
        XCTAssertEqual(l, before)
    }

    func testShowWhileExpandedClearsExpansion() {
        var l = split()
        l.toggleExpand(.board)
        l.show(.documents)
        XCTAssertNil(l.expanded)
        XCTAssertEqual(l.visiblePanes, [.board, .documents])
    }

    func testForgetSecondaryBecomesSingle() {
        var l = split()
        l.forgetSession(1, fallback: .board)
        XCTAssertEqual(l, .default)
    }

    func testForgetPrimaryPromotesSecondaryOrFallsBack() {
        var l = WorkspaceLayout(primary: .session(7), secondary: .documents, expanded: nil, dividerFraction: 0.5)
        l.forgetSession(7, fallback: .board)
        XCTAssertEqual(l.primary, .documents)
        XCTAssertNil(l.secondary)

        var single = WorkspaceLayout(primary: .session(7), secondary: nil, expanded: nil, dividerFraction: 0.5)
        single.forgetSession(7, fallback: .board)
        XCTAssertEqual(single.primary, .board)
    }

    func testForgetExpandedClearsExpansion() {
        var l = split()
        l.toggleExpand(.session(1))
        l.forgetSession(1, fallback: .board)
        XCTAssertNil(l.expanded)
        XCTAssertEqual(l.visiblePanes, [.board])
    }

    func testForgetOtherSessionChangesNothing() {
        var l = split()
        l.forgetSession(99, fallback: .board)
        XCTAssertEqual(l, split())
    }

    func testJSONRoundTrip() throws {
        var l = split()
        l.toggleExpand(.session(1))
        l.dividerFraction = 0.3
        let data = try JSONEncoder().encode(l)
        XCTAssertEqual(WorkspaceLayout.decode(data), l)
    }

    func testDecodeJunkAndMissingGiveDefault() {
        XCTAssertEqual(WorkspaceLayout.decode(Data("junk".utf8)), .default)
        XCTAssertEqual(WorkspaceLayout.decode(nil), .default)
    }

    func testDecodeClampsFraction() throws {
        var l = WorkspaceLayout.default
        l.dividerFraction = 1.5
        XCTAssertEqual(WorkspaceLayout.decode(try JSONEncoder().encode(l)).dividerFraction, 0.8)
        l.dividerFraction = -1
        XCTAssertEqual(WorkspaceLayout.decode(try JSONEncoder().encode(l)).dividerFraction, 0.2)
    }

    func testKey() {
        XCTAssertEqual(WorkspaceLayout.key(projectID: 12), "projects.layout.12")
    }
}
