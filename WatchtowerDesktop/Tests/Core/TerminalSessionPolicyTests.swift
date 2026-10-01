import XCTest
@testable import WatchtowerCore

final class TerminalSessionPolicyTests: XCTestCase {
    private func make(
        _ id: Int64,
        kind: TerminalSession.Kind = .claude,
        source: TerminalSession.TitleSource = .auto,
        target: Int64? = nil,
        active: String = "2026-09-30T10:00:00Z"
    ) -> TerminalSession {
        TerminalSession(
            id: id, projectID: 1, kind: kind, title: "t\(id)", titleSource: source, targetID: target,
            folderPath: "/tmp", claudeSessionID: nil, createdAt: "2026-09-30T09:00:00Z",
            lastActiveAt: active)
    }

    func testActivePrefersLastFocusedLiveClaude() {
        let s = [make(1), make(2), make(3)]
        XCTAssertEqual(TerminalSessionPolicy.activeSession(s, live: [1, 2, 3], lastFocused: [3, 1])?.id, 1)
    }

    func testActiveSkipsNonLiveAndShellInFocusOrder() {
        let s = [make(1), make(2, kind: .shell), make(3)]
        XCTAssertEqual(TerminalSessionPolicy.activeSession(s, live: [1, 2], lastFocused: [1, 2, 3])?.id, 1)
    }

    func testActiveFallsBackToMostRecentlyActive() {
        let s = [make(1, active: "2026-09-30T10:00:00Z"), make(2, active: "2026-09-30T11:00:00Z")]
        XCTAssertEqual(TerminalSessionPolicy.activeSession(s, live: [1, 2], lastFocused: [])?.id, 2)
    }

    func testActiveNilWhenNoneLive() {
        XCTAssertNil(TerminalSessionPolicy.activeSession([make(1)], live: [], lastFocused: [1]))
        XCTAssertNil(TerminalSessionPolicy.activeSession([make(1, kind: .shell)], live: [1], lastFocused: [1]))
    }

    func testSessionForTargetPicksMostRecent() {
        let s = [
            make(1, target: 5, active: "2026-09-30T10:00:00Z"),
            make(2, target: 5, active: "2026-09-30T12:00:00Z"),
            make(3, target: 6, active: "2026-09-30T13:00:00Z")
        ]
        XCTAssertEqual(TerminalSessionPolicy.sessionForTarget(5, in: s)?.id, 2)
        XCTAssertNil(TerminalSessionPolicy.sessionForTarget(9, in: s))
    }

    func testSessionForTargetTieBrokenByHigherID() {
        let s = [make(1, target: 5), make(2, target: 5)]
        XCTAssertEqual(TerminalSessionPolicy.sessionForTarget(5, in: s)?.id, 2)
    }

    func testNeedsTitleTable() {
        XCTAssertTrue(TerminalSessionPolicy.needsTitle(make(1), attempts: 0))
        XCTAssertTrue(TerminalSessionPolicy.needsTitle(make(1), attempts: 4))
        XCTAssertFalse(TerminalSessionPolicy.needsTitle(make(1), attempts: 5))
        XCTAssertFalse(TerminalSessionPolicy.needsTitle(make(1, kind: .shell), attempts: 0))
        XCTAssertFalse(TerminalSessionPolicy.needsTitle(make(1, source: .ai), attempts: 0))
        XCTAssertFalse(TerminalSessionPolicy.needsTitle(make(1, source: .user), attempts: 0))
        XCTAssertFalse(TerminalSessionPolicy.needsTitle(make(1, target: 3), attempts: 0))
        var setup = make(1)
        setup.title = TerminalSessionNaming.setupTitle
        XCTAssertFalse(TerminalSessionPolicy.needsTitle(setup, attempts: 0))
    }
}
