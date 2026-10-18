import XCTest
import GRDB
@testable import WatchtowerCore

/// #573: the add-site sheet's "Also connect Confluence" half.
final class ConfluenceConnectStepTests: XCTestCase {

    private func account(_ id: Int, enabled: Bool = true) -> JiraAccount {
        JiraAccount(row: ["id": id, "enabled": enabled])
    }

    func testAddedSitesAreOnlyTheEnabledNewOnes() {
        let accounts = [account(1), account(2), account(3, enabled: false)]
        XCTAssertEqual(ConfluenceConnectStep.addedSites(accounts, before: [1]).map(\.id), [2])
        // A re-consent of a known site adds none — and, unlike the board
        // list, does not fall back to every site.
        XCTAssertTrue(ConfluenceConnectStep.addedSites(accounts, before: [1, 2, 3]).isEmpty)
        // A failed before-read selects nowhere.
        XCTAssertTrue(ConfluenceConnectStep.addedSites(accounts, before: nil).isEmpty)
    }

    func testSelectArgs() {
        XCTAssertEqual(
            ConfluenceConnectStep.selectArgs(accountID: 4),
            ["confluence", "--account", "4", "select", "--recent"]
        )
    }

    func testSummaryNamesSpacesNoneOrFailure() {
        XCTAssertEqual(
            ConfluenceConnectStep.summary(spaceNames: ["Engineering", "Operations"], failures: []),
            "Confluence: syncing the spaces you work in — Engineering, Operations. "
                + "Change them in Settings → Connections → Jira."
        )
        XCTAssertEqual(
            ConfluenceConnectStep.summary(spaceNames: [], failures: []),
            "Confluence: no space you wrote in or viewed lately. Choose spaces in Settings → Connections → Jira."
        )
        // A failure wins over whatever got selected before it.
        XCTAssertEqual(
            ConfluenceConnectStep.summary(spaceNames: ["Engineering"], failures: ["access not granted"]),
            "Confluence: couldn't choose spaces (access not granted). Choose them in Settings → Connections → Jira."
        )
        XCTAssertEqual(
            ConfluenceConnectStep.summary(siteFound: false, spaceNames: [], failures: []),
            "Confluence: choose spaces in Settings → Connections → Jira."
        )
    }
}
