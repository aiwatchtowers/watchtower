import XCTest
import GRDB
@testable import WatchtowerCore

final class JiraBoardPickerTests: XCTestCase {

    private func board(_ accountID: Int64, _ id: Int, selected: Bool = false) -> JiraBoard {
        JiraBoard(
            accountID: accountID, id: id, name: "Board \(id)", projectKey: "PROJ", boardType: "scrum",
            isSelected: selected, issueCount: 0, syncedAt: "", rawColumnsJSON: "", rawConfigJSON: "",
            llmProfileJSON: "", workflowSummary: "", userOverridesJSON: "", configHash: "", profileGeneratedAt: ""
        )
    }

    private func account(_ id: Int, enabled: Bool = true) -> JiraAccount {
        JiraAccount(row: ["id": id, "enabled": enabled])
    }

    func testBoardsKeepOnlyEnabledSites() {
        let boards = [board(1, 10), board(2, 20), board(3, 30)]
        let listed = JiraBoardPicker.boards(boards, of: [account(1), account(2, enabled: false)])
        XCTAssertEqual(listed.map(\.rowID), ["1:10"])
    }

    func testStartingChoiceIsTheCurrentSelection() {
        let boards = [board(1, 10, selected: true), board(1, 11), board(2, 10, selected: true)]
        XCTAssertEqual(JiraBoardPicker.selected(boards), ["1:10", "2:10"])
    }

    func testInvocationsCarryOnlyChangesPerSiteAndDirection() {
        let boards = [
            board(2, 7), board(1, 12), board(1, 10), board(1, 11, selected: true),
            board(1, 13, selected: true), board(2, 8, selected: true)
        ]
        // Choose 1:10, 1:12, 2:7; keep 1:13; drop 1:11 and 2:8.
        let calls = JiraBoardPicker.invocations(for: boards, chosen: ["1:10", "1:12", "1:13", "2:7"])
        XCTAssertEqual(calls, [
            ["jira", "--account", "1", "boards", "select", "10", "12"],
            ["jira", "--account", "1", "boards", "deselect", "11"],
            ["jira", "--account", "2", "boards", "select", "7"],
            ["jira", "--account", "2", "boards", "deselect", "8"]
        ])
    }

    func testNoChangeNoCalls() {
        let boards = [board(1, 10, selected: true), board(1, 11)]
        XCTAssertEqual(JiraBoardPicker.invocations(for: boards, chosen: ["1:10"]), [])
    }
}
