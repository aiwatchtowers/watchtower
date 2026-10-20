import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

/// The Workbench zone's builder: which sessions and asks Home shows, grouped
/// by workbench.
final class HomeWorkbenchBuilderTests: XCTestCase {
    private func session(
        _ id: Int64, workbench: Int64? = 1, name: String? = "acme", _ kind: SessionSwitcherPresentation.State.Kind
    ) -> SessionAgentStatus {
        SessionAgentStatus(
            sessionID: id, workbenchID: workbench, workbenchName: name, title: "Session \(id)",
            state: SessionSwitcherPresentation.State(kind: kind, live: true), at: nil
        )
    }

    /// Open asks read through the real query, so the rows are real `OwnerAsk`s.
    private func asks(_ build: (Database) throws -> Void) throws -> WorkbenchAskRows {
        let db = try TestDatabase.create()
        return try db.write { d in
            try build(d)
            return try OwnerAskQueries.openAsksAllWorkbenches(d)
        }
    }

    func testFinishedAndStoppedLeftOut() {
        let sessions = [
            session(1, .finished), session(2, .stopped), session(3, .running), session(4, .notStarted),
            session(5, .waitingOnAsk), session(6, .working)
        ]
        let blocks = HomeWorkbenchBuilder.blocks(sessions: sessions, asks: WorkbenchAskRows(rows: [], unreadableIDs: []))
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].sessions.map(\.sessionID), [6])
    }

    func testSessionWithoutAWorkbenchIsLeftOut() {
        let blocks = HomeWorkbenchBuilder.blocks(
            sessions: [session(1, workbench: nil, name: nil, .working)],
            asks: WorkbenchAskRows(rows: [], unreadableIDs: [])
        )
        XCTAssertTrue(blocks.isEmpty)
    }

    func testBlocksByNameSessionsByKind() throws {
        let rows = try asks { d in
            let acme = try TestDatabase.insertWorkbench(d, name: "acme", folder: "/tmp/acme")
            let beta = try TestDatabase.insertWorkbench(d, name: "beta", folder: "/tmp/beta")
            _ = try TestDatabase.insertOwnerAsk(d, projectID: acme, title: "New", createdAt: "2026-10-19T10:00:00Z")
            _ = try TestDatabase.insertOwnerAsk(d, projectID: acme, title: "Old", createdAt: "2026-10-19T08:00:00Z")
            _ = try TestDatabase.insertOwnerAsk(d, projectID: beta, title: "Beta")
        }
        let sessions = [
            session(1, workbench: 2, name: "beta", .working),
            session(2, workbench: 1, name: "acme", .working),
            session(3, workbench: 1, name: "acme", .needsApproval),
            session(4, workbench: 1, name: "acme", .background),
            session(5, workbench: 1, name: "acme", .readyToCheck),
            session(6, workbench: 1, name: "acme", .failed)
        ]
        let blocks = HomeWorkbenchBuilder.blocks(sessions: sessions, asks: rows)
        XCTAssertEqual(blocks.map(\.name), ["acme", "beta"])
        XCTAssertEqual(blocks[0].sessions.map(\.sessionID), [3, 6, 5, 4, 2])
        XCTAssertEqual(blocks[0].asks.map(\.ask.title), ["Old", "New"])
        XCTAssertEqual(blocks[1].sessions.map(\.sessionID), [1])
        XCTAssertEqual(blocks[1].asks.map(\.ask.title), ["Beta"])
    }

    func testWorkbenchWithOnlyAnAskShows() throws {
        let rows = try asks { d in
            let id = try TestDatabase.insertWorkbench(d, name: "acme")
            _ = try TestDatabase.insertOwnerAsk(d, projectID: id, title: "Check it")
        }
        let blocks = HomeWorkbenchBuilder.blocks(sessions: [session(1, .finished)], asks: rows)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].name, "acme")
        XCTAssertTrue(blocks[0].sessions.isEmpty)
        XCTAssertEqual(blocks[0].asks.count, 1)
    }

    func testLinks() throws {
        XCTAssertEqual(
            HomeWorkbenchBuilder.link(for: session(7, workbench: 3, .working)),
            .workbench(WorkbenchRoute(projectID: 3, pane: .terminal, subjectID: 7))
        )
        XCTAssertNil(HomeWorkbenchBuilder.link(for: session(7, workbench: nil, name: nil, .working)))
        XCTAssertEqual(
            HomeWorkbenchBuilder.link(for: session(7, workbench: 3, .readyToCheck)),
            .workbench(WorkbenchRoute(projectID: 3, pane: .review, subjectID: 7)),
            "a session ready to check opens in its Branch review"
        )
        for kind: SessionSwitcherPresentation.State.Kind in [.needsApproval, .failed, .background] {
            XCTAssertEqual(
                HomeWorkbenchBuilder.link(for: session(7, workbench: 3, kind)),
                .workbench(WorkbenchRoute(projectID: 3, pane: .terminal, subjectID: 7)), "\(kind)"
            )
        }
        let rows = try asks { d in
            let id = try TestDatabase.insertWorkbench(d)
            _ = try TestDatabase.insertOwnerAsk(d, projectID: id)
        }
        let row = try XCTUnwrap(rows.rows.first)
        XCTAssertEqual(
            HomeWorkbenchBuilder.link(for: row),
            .workbench(.forAsk(projectID: row.ask.projectID, sessionID: nil, askID: row.ask.id))
        )
    }
}
