import XCTest
@testable import WatchtowerCore

final class WorkspaceLayoutChangesTests: XCTestCase {
    func testChangesPaneRoundTripsAndMapsToItsView() throws {
        let pane = WorkspacePane.changes(42)
        let data = try JSONEncoder().encode(pane)
        XCTAssertEqual(try JSONDecoder().decode(WorkspacePane.self, from: data), pane)
        XCTAssertEqual(WorkspaceView(pane), .changes)
    }

    func testUnknownSavedPaneStillDecodesToDefault() {
        let legacy = Data(#"{"primary":{"somethingNew":{}}}"#.utf8)
        XCTAssertEqual(WorkspaceLayout.decode(legacy), .default)
    }

    func testDeletedSessionTakesItsChangesPaneWithIt() {
        var l = WorkspaceLayout(primary: .session(7), secondary: .changes(7), expanded: nil, dividerFraction: 0.5)
        l.forgetSession(7, fallback: .board)
        XCTAssertEqual(l.visiblePanes, [.board])

        var other = WorkspaceLayout(primary: .board, secondary: .changes(7), expanded: .changes(7), dividerFraction: 0.5)
        other.forgetSession(7, fallback: .board)
        XCTAssertEqual(other.visiblePanes, [.board])
    }
}
