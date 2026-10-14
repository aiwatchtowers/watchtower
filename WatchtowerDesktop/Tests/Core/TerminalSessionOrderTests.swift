import XCTest
@testable import WatchtowerCore

final class TerminalSessionOrderTests: XCTestCase {
    private func make(_ id: Int64, active: String = "2026-09-30T10:00:00Z") -> TerminalSession {
        TerminalSession(
            id: id, projectID: 1, kind: .claude, title: "t\(id)", titleSource: .auto, targetID: nil,
            folderPath: "/tmp", claudeSessionID: nil, createdAt: "2026-09-30T09:00:00Z",
            lastActiveAt: active)
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

    func testNoOpDragsKeepTheOrder() {
        let shown = [make(3), make(2), make(1)]
        XCTAssertEqual(TerminalSessionOrder.move(shown, from: [1], to: 1), [3, 2, 1])
        XCTAssertEqual(TerminalSessionOrder.move(shown, from: [1], to: 2), [3, 2, 1])
    }

    func testMoveABlockToTheEnd() {
        let shown = [make(4), make(3), make(2), make(1)]
        XCTAssertEqual(TerminalSessionOrder.move(shown, from: [0, 1], to: 4), [2, 1, 4, 3])
    }

    func testMoveWithinKeepsHiddenSlots() {
        // 9 sits in the finished group, between two main rows.
        let shown = [make(3), make(2), make(1)]
        let saved = TerminalSessionOrder.move(shown, within: [3, 9, 2, 1], from: [0], to: 3)
        XCTAssertEqual(saved, [2, 9, 1, 3], "the hidden id keeps its index")
        let back = TerminalSessionOrder.apply([make(1), make(2), make(3), make(9)], saved: saved)
        XCTAssertEqual(ids(back), [2, 9, 1, 3], "returning to the main list restores its place")
        XCTAssertEqual(TerminalSessionOrder.move(shown, within: [9, 2, 1], from: [2], to: 0), [3, 9, 1, 2],
                       "a displayed id missing from the full order goes on top")
    }

    func testKey() {
        XCTAssertEqual(TerminalSessionOrder.key(workbenchID: 7), "projects.sessionOrder.7")
        XCTAssertEqual(TerminalSessionOrder.key(workbenchID: nil), "projects.sessionOrder.standalone")
    }
}
