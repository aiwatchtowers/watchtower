import XCTest
@testable import WatchtowerCore

final class SessionRowDragTests: XCTestCase {
    private func make(_ id: Int64) -> TerminalSession {
        TerminalSession(
            id: id, projectID: 1, kind: .claude, title: "t\(id)", titleSource: .auto, targetID: nil,
            folderPath: "/tmp", claudeSessionID: nil, createdAt: "2026-09-30T09:00:00Z",
            lastActiveAt: "2026-09-30T10:00:00Z")
    }

    func testPayloadRoundTripsWithinItsList() {
        let workbench = SessionRowDrag.payload(listID: 7, sessionID: 42)
        XCTAssertEqual(SessionRowDrag.sessionID(from: workbench, listID: 7), 42)
        let standalone = SessionRowDrag.payload(listID: nil, sessionID: 9)
        XCTAssertEqual(SessionRowDrag.sessionID(from: standalone, listID: nil), 9)
    }

    func testForeignOrOtherListPayloadMovesNothing() {
        XCTAssertNil(SessionRowDrag.sessionID(from: "hello", listID: 7))
        XCTAssertNil(SessionRowDrag.sessionID(from: "watchtower.session-row:7:x", listID: 7))
        XCTAssertNil(SessionRowDrag.sessionID(from: SessionRowDrag.payload(listID: 8, sessionID: 1), listID: 7))
        XCTAssertNil(SessionRowDrag.sessionID(from: SessionRowDrag.payload(listID: nil, sessionID: 1), listID: 7))
        XCTAssertNil(SessionRowDrag.sessionID(from: SessionRowDrag.payload(listID: 7, sessionID: 1), listID: nil))
    }

    func testDropTakesTheTargetSlotInEitherDirection() throws {
        let displayed = [make(1), make(2), make(3), make(4)]
        let ids = displayed.map(\.id)
        let down = try XCTUnwrap(SessionRowDrag.move(1, onto: 3, in: ids))
        XCTAssertEqual(TerminalSessionOrder.move(displayed, from: down.source, to: down.destination), [2, 3, 1, 4])
        let up = try XCTUnwrap(SessionRowDrag.move(4, onto: 2, in: ids))
        XCTAssertEqual(TerminalSessionOrder.move(displayed, from: up.source, to: up.destination), [1, 4, 2, 3])
        let toEnd = try XCTUnwrap(SessionRowDrag.move(1, onto: 4, in: ids))
        XCTAssertEqual(TerminalSessionOrder.move(displayed, from: toEnd.source, to: toEnd.destination), [2, 3, 4, 1])
    }

    func testNoMoveOnItselfOrUnlistedRows() {
        XCTAssertNil(SessionRowDrag.move(2, onto: 2, in: [1, 2, 3]))
        XCTAssertNil(SessionRowDrag.move(9, onto: 2, in: [1, 2, 3]))
        XCTAssertNil(SessionRowDrag.move(1, onto: 9, in: [1, 2, 3]))
    }
}
