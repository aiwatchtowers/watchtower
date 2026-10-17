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

    func testSitesAreTheAddedOnesElseEveryEnabledSite() {
        let accounts = [account(1), account(2), account(3, enabled: false), account(4)]
        XCTAssertEqual(JiraBoardPicker.sites(accounts, before: [1, 2]).map(\.id), [4])
        // A re-consent of a known site adds none: every enabled site.
        XCTAssertEqual(JiraBoardPicker.sites(accounts, before: [1, 2, 3, 4]).map(\.id), [1, 2, 4])
        // A disabled new site is not listed.
        XCTAssertEqual(JiraBoardPicker.sites(accounts, before: [1, 2, 4]).map(\.id), [1, 2, 4])
        XCTAssertEqual(JiraBoardPicker.sites(accounts, before: nil).map(\.id), [1, 2, 4])
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
