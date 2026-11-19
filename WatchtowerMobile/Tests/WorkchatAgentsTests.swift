import WatchtowerKit
import XCTest
@testable import WatchtowerMobile

/// The phone's agents list (#2065, spec §2): subagent entries leave the dialog and sort into Working and Done.
final class WorkchatAgentsTests: XCTestCase {
    private func owner(_ id: String) -> SessionChat.Entry { SessionChat.Entry(id: id, kind: .owner, text: "hi") }
    private func agent(_ id: String) -> SessionChat.Entry { SessionChat.Entry(id: id, kind: .agent, text: "ok") }

    private func marker(_ id: String, _ status: String, ids: Bool = true) -> SessionChat.Entry {
        SessionChat.Entry(
            id: id, kind: .subagent, text: "",
            subagent: .init(
                agentID: ids ? "ag-\(id)" : "", toolUseID: ids ? "tu-\(id)" : "",
                type: "Explore", description: "Look \(id)", status: status
            )
        )
    }

    func testDialogDropsSubagentEntries() {
        XCTAssertEqual(WorkchatAgents.dialog([owner("o1"), marker("s1", "running"), agent("a1")]).map(\.id), ["o1", "a1"])
    }

    func testSectionsFromMarkers() {
        let agents = WorkchatAgents(entries: [marker("w1", "running"), marker("d1", "finished"), marker("d2", "finished")], sessionID: 3)
        XCTAssertEqual(agents.working.map(\.id), ["w1"])
        XCTAssertEqual(agents.done.map(\.id), ["d2", "d1"], "newest first")
        XCTAssertEqual(agents.badge, .working(1))
        XCTAssertFalse(agents.doneOpenByDefault)
    }

    func testOnlyDoneBadgeAndOpen() {
        let agents = WorkchatAgents(entries: [marker("d1", "finished"), marker("d2", "finished")], sessionID: 3)
        XCTAssertEqual(agents.badge, .done(2))
        XCTAssertTrue(agents.doneOpenByDefault)
        XCTAssertEqual(WorkchatAgentsText.doneBadge(2), "✓ 2")
    }

    func testNoAgentsNoButton() {
        XCTAssertNil(WorkchatAgents(entries: [owner("o1"), agent("a1")], sessionID: 3).badge)
    }

    func testUnknownStatusInNeitherSection() {
        let agents = WorkchatAgents(entries: [marker("x", "weird")], sessionID: 3)
        XCTAssertTrue(agents.working.isEmpty)
        XCTAssertTrue(agents.done.isEmpty)
        XCTAssertNil(agents.badge)
    }

    func testRowsRouteToTheAgentsChat() throws {
        let agents = WorkchatAgents(entries: [marker("w1", "running"), marker("w2", "running", ids: false)], sessionID: 3)
        XCTAssertEqual(agents.working[0].route, SessionChatRoute(sessionID: 3, agentID: "ag-w1", toolUseID: "tu-w1"))
        XCTAssertNil(agents.working[1].route)
        XCTAssertEqual(agents.working[0].type, "Explore")
        XCTAssertEqual(agents.working[0].description, "Look w1")
    }

    func testOwnerDoneChoiceSurvivesDefaultChange() {
        let working = WorkchatAgents(entries: [marker("w", "running"), marker("d", "finished")], sessionID: 3)
        let idle = WorkchatAgents(entries: [marker("d", "finished")], sessionID: 3)
        XCTAssertFalse(working.doneIsOpen(.automatic))
        XCTAssertTrue(idle.doneIsOpen(.automatic))
        XCTAssertTrue(working.doneIsOpen(.open), "opened while working, stays open once the default flips")
        XCTAssertTrue(idle.doneIsOpen(.open))
        XCTAssertFalse(idle.doneIsOpen(.closed), "closed by the owner beats the open default")
        XCTAssertFalse(working.doneIsOpen(.closed))
    }

    func testBadgeValue() {
        XCTAssertEqual(WorkchatAgentsText.badgeValue(.working(2)), "2 working")
        XCTAssertEqual(WorkchatAgentsText.badgeValue(.done(3)), "3 done")
    }

    func testStrings() {
        XCTAssertEqual(WorkchatAgentsText.done(9), "Done · 9")
        XCTAssertEqual(WorkchatAgentsText.running, "Running")
        XCTAssertEqual(WorkchatAgentsText.title, "Agents")
        XCTAssertEqual(WorkchatAgentsText.working, "Working")
        XCTAssertEqual(WorkchatAgentsText.close, "Close")
    }
}
