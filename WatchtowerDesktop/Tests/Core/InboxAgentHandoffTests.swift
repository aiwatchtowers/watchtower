import GRDB
import XCTest
@testable import WatchtowerCore

/// Hand to Agent…'s workbench (spec B2): the action's own ref, else a
/// workbench recipe's own workbench; anything that names no one existing
/// workbench is the owner's pick.
final class InboxAgentHandoffTests: XCTestCase {
    private let workbenches = [workbench(3, "acme"), workbench(4, "Docs"), workbench(5, "docs")]

    private static func workbench(_ id: Int64, _ name: String) -> Workbench {
        Workbench(row: Row(["id": id, "name": name, "folder_path": "/acme/\(id)"]))
    }

    private func card(workbenchID: Int64?) -> AutomationOutputCard {
        AutomationOutputCard(id: 1, automationID: 2, automationName: "Mail digest", runID: 9, title: "Reply",
                             body: "", priority: "normal", createdAt: Date(timeIntervalSince1970: 0),
                             workbenchID: workbenchID)
    }

    func testWorkbenchRecipeDefaultsToItsOwn() {
        XCTAssertEqual(InboxAgentHandoff.workbench(for: nil, card: card(workbenchID: 3), workbenches: workbenches),
                       .workbench(3))
    }

    func testIdAndNameResolve() {
        let personal = card(workbenchID: nil)
        XCTAssertEqual(InboxAgentHandoff.workbench(for: .id(3), card: personal, workbenches: workbenches), .workbench(3))
        XCTAssertEqual(InboxAgentHandoff.workbench(for: .name("ACME"), card: personal, workbenches: workbenches),
                       .workbench(3))
        XCTAssertEqual(InboxAgentHandoff.workbench(for: .id(4), card: card(workbenchID: 3), workbenches: workbenches),
                       .workbench(4), "the action's own ref wins over the recipe's workbench")
    }

    func testUnknownOrAmbiguousPicks() {
        let personal = card(workbenchID: nil)
        XCTAssertEqual(InboxAgentHandoff.workbench(for: .id(99), card: personal, workbenches: workbenches), .pick)
        XCTAssertEqual(InboxAgentHandoff.workbench(for: .name("nope"), card: personal, workbenches: workbenches), .pick)
        XCTAssertEqual(InboxAgentHandoff.workbench(for: .name("docs"), card: personal, workbenches: workbenches), .pick,
                       "two workbenches match the name")
        XCTAssertEqual(InboxAgentHandoff.workbench(for: nil, card: personal, workbenches: workbenches), .pick)
        XCTAssertEqual(InboxAgentHandoff.workbench(for: nil, card: card(workbenchID: 99), workbenches: workbenches),
                       .pick, "the recipe's workbench is gone")
    }
}
