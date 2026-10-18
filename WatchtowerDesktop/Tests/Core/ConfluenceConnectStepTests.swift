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

    func testArgs() {
        XCTAssertEqual(ConfluenceConnectStep.accessArgs(accountID: 4), ["confluence", "--account", "4", "access", "--json"])
        XCTAssertEqual(ConfluenceConnectStep.selectArgs(accountID: 4), ["confluence", "--account", "4", "select", "--recent"])
    }

    func testFailureTextNeverShowsACommand() {
        XCTAssertEqual(
            ConfluenceConnectStep.failureText("Error: Confluence access not granted — run: watchtower jira login --account 1 --with-confluence"),
            "Confluence access isn't granted"
        )
        XCTAssertEqual(ConfluenceConnectStep.failureText("listing Confluence spaces: timeout"), "listing Confluence spaces: timeout")
    }

    func testLines() {
        XCTAssertEqual(
            ConfluenceConnectStep.line(.selected(["Engineering"])),
            "Confluence: syncing 1 space you work in — Engineering. Choose more in Settings → Connections → Jira."
        )
        XCTAssertEqual(
            ConfluenceConnectStep.line(.selected(["Engineering", "Operations"])),
            "Confluence: syncing 2 spaces you work in — Engineering, Operations. Choose more in Settings → Connections → Jira."
        )
        XCTAssertEqual(
            ConfluenceConnectStep.line(.selected([])),
            "Confluence: no space you wrote in or viewed in the last 90 days. Choose spaces in Settings → Connections → Jira."
        )
        XCTAssertEqual(
            ConfluenceConnectStep.line(.failed(["timeout"])),
            "Confluence: couldn't choose spaces (timeout). Choose them in Settings → Connections → Jira."
        )
        XCTAssertEqual(
            ConfluenceConnectStep.line(.notEnabled),
            "Jira connected; Confluence isn't enabled for this Atlassian app."
        )
        XCTAssertEqual(
            ConfluenceConnectStep.line(.featureOff),
            "Turn on Confluence in search (Settings → Features) to sync your spaces."
        )
        XCTAssertEqual(ConfluenceConnectStep.line(.noSite), "Confluence: choose spaces in Settings → Connections → Jira.")
    }
}
