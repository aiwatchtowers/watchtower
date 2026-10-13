import XCTest
@testable import WatchtowerCore

/// The session switcher popover's lists (#480,
/// `SessionPanelSections.switcherRows(matching:)`): the panel's main rows,
/// then under a "Finished" divider every finished session — folded in the
/// panel or not — each list filtered by the find field.
final class SessionSwitcherPopoverTests: XCTestCase {
    private let now = Date()

    private func session(_ id: Int64, _ title: String) -> TerminalSession {
        let stamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-60))
        return TerminalSession(
            id: id, projectID: 1, kind: .claude, title: title, titleSource: .auto, targetID: nil,
            folderPath: "/tmp/acme", claudeSessionID: "uuid", createdAt: stamp, lastActiveAt: stamp
        )
    }

    private func finished(_ id: Int64, at stamp: String) -> SessionAgentStatus {
        SessionAgentStatus(sessionID: id, workbenchID: 1, workbenchName: "acme", title: "t",
                           state: .init(kind: .finished, live: false), at: nil, finishedAt: stamp)
    }

    /// Sessions 1 "Fix login", 2 "Docs pass" (finished), 3 "Login copy",
    /// 4 "Release notes" (finished later); the group folded.
    private func sections() -> SessionPanelSections {
        let sessions = [session(1, "Fix login"), session(2, "Docs pass"), session(3, "Login copy"),
                        session(4, "Release notes")]
        let statuses: [Int64: SessionAgentStatus] = [
            2: finished(2, at: "2026-10-12T09:00:00.000Z"), 4: finished(4, at: "2026-10-12T10:00:00.000Z")
        ]
        return SessionPanelSections.grouping(
            sessions: sessions, savedOrder: [1, 2, 3, 4], statuses: statuses, liveIDs: [], now: now,
            expanded: false, sticky: nil
        )
    }

    func testEmptyQuerySplitsMainAndEveryFinishedRow() {
        let (main, finished) = sections().switcherRows(matching: "")
        XCTAssertEqual(main.map(\.id), [1, 3], "the panel's main list in its order")
        XCTAssertEqual(finished.map(\.id), [4, 2], "every group row, folded or not, newest finished first")
        XCTAssertEqual(main.map(\.shortcut), [1, 2])
        XCTAssertEqual(finished.map(\.shortcut), [nil, nil], "a folded group's rows get no number")
    }

    func testQueryFiltersBothLists() {
        let (main, finished) = sections().switcherRows(matching: "LOGIN")
        XCTAssertEqual(main.map(\.id), [1, 3])
        XCTAssertTrue(finished.isEmpty, "no finished row matches: no divider")

        let notes = sections().switcherRows(matching: "notes")
        XCTAssertTrue(notes.main.isEmpty)
        XCTAssertEqual(notes.finished.map(\.id), [4], "a finished row is found while folded in the panel")

        let none = sections().switcherRows(matching: "nothing here")
        XCTAssertTrue(none.main.isEmpty && none.finished.isEmpty)
    }
}
