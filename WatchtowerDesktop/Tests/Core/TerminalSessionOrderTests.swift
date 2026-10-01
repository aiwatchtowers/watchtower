import XCTest
@testable import WatchtowerCore

final class TerminalSessionOrderTests: XCTestCase {
    private func make(_ id: Int64, active: String = "2026-09-30T10:00:00Z") -> TerminalSession {
        TerminalSession(
            id: id, projectID: 1, kind: .claude, title: "t\(id)", titleSource: .auto, targetID: nil,
            folderPath: "/tmp", claudeSessionID: nil, createdAt: "2026-09-30T09:00:00Z",
            lastActiveAt: active, closedAt: nil)
    }

    private func ids(_ sessions: [TerminalSession]) -> [Int64] { sessions.map(\.id) }

    func testNeverPlacedIsNewestFirstWhateverTheRecency() {
        let rows = [make(1, active: "2026-09-30T12:00:00Z"), make(3), make(2, active: "2026-09-30T11:00:00Z")]
        XCTAssertEqual(ids(TerminalSessionOrder.apply(rows, saved: [])), [3, 2, 1])
    }

    func testSavedOrderHoldsAndANewSessionGoesOnTop() {
        let rows = [make(1), make(2), make(3), make(4)]
        XCTAssertEqual(ids(TerminalSessionOrder.apply(rows, saved: [2, 1, 3])), [4, 2, 1, 3])
    }

    func testGoneAndDuplicateSavedIDsAreSkipped() {
        let rows = [make(1), make(2)]
        XCTAssertEqual(ids(TerminalSessionOrder.apply(rows, saved: [9, 2, 2, 1])), [2, 1])
    }

    func testMoveDown() {
        let shown = [make(3), make(2), make(1)]
        XCTAssertEqual(TerminalSessionOrder.move(shown, from: [0], to: 3), [2, 1, 3])
    }

    func testMoveUp() {
        let shown = [make(3), make(2), make(1)]
        XCTAssertEqual(TerminalSessionOrder.move(shown, from: [2], to: 0), [1, 3, 2])
    }

    func testMoveSeveral() {
        let shown = [make(5), make(4), make(3), make(2), make(1)]
        XCTAssertEqual(TerminalSessionOrder.move(shown, from: [0, 2], to: 4), [4, 2, 5, 3, 1])
    }

    func testKey() {
        XCTAssertEqual(TerminalSessionOrder.key(projectID: 7), "projects.sessionOrder.7")
        XCTAssertEqual(TerminalSessionOrder.key(projectID: nil), "projects.sessionOrder.standalone")
    }
}
