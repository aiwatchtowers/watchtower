import GRDB
import XCTest
@testable import WatchtowerCore

/// The connect section of screens spec §4.2/§4.4 (plan B Task 14).
extension SlackModePresentationTests {
    private func connectAccount(team: String, client: String, status: String = "ok") -> SlackAccount {
        SlackAccount(row: Row([
            "id": 1, "team_id": team, "team_name": "acme", "team_domain": "", "label": "",
            "status": status, "error": "", "enabled": true, "client_id": client
        ]))
    }

    private func section(
        _ display: SlackModePresentation.Display = .off,
        portBusy: Bool = false,
        expanded: Bool = false,
        apps: [ManagedPolicy.SlackApp]? = nil,
        accounts: [SlackAccount] = [],
        builtinApp: Bool = true
    ) -> SlackModePresentation.ConnectSection {
        .init(display: display, portBusy: portBusy, expanded: expanded, organizationApps: apps, accounts: accounts,
              builtinApp: builtinApp)
    }

    func testConnectSectionStrings() {
        let s = section()
        XCTAssertEqual(s.title, "Connect your workspace's app")
        XCTAssertEqual(s.caption, "Open Watchtower's app in Slack, go to its About tab and click the connect link. "
            + "No clickable link? Paste the link or the connect code here.")
        XCTAssertEqual(s.organizationTitle, "Set up by your organization")
        XCTAssertEqual(s.fieldPlaceholder, "Connect link or code")
        XCTAssertEqual(s.connect, "Connect")
        XCTAssertEqual(s.noAppYet, "No Watchtower app in your workspace yet?")
        XCTAssertEqual(s.setUpForCompany, "Set up for my company")
        XCTAssertEqual(s.foldButton, "Connect another workspace…")
        XCTAssertEqual(s.disclosure, "Watchtower keeps a copy of what you can see in your workspace on this Mac and "
            + "sends message text to your AI provider.")
        XCTAssertEqual(s.disclosure, SlackDisclosureCopy.connectLine(workspace: "your workspace"))
        XCTAssertEqual(s.privacyLink, "Privacy policy")
        XCTAssertEqual(s.privacyURL, SlackDisclosureCopy.privacyURL)
        XCTAssertEqual(s.organizationRows, [])
        XCTAssertNil(s.portBusyLine)
        XCTAssertFalse(s.isFolded)
        XCTAssertFalse(s.showsFoldButton)
    }

    func testPortBusyLine() {
        XCTAssertEqual(section(portBusy: true).portBusyLine,
                       "The connect link cannot reach Watchtower: port 18551 is busy. "
                           + "Quit the app holding port 18551, then open Connections → Slack again to retry.")
        XCTAssertNil(section(portBusy: false).portBusyLine)
    }

    func testFullFoldsConnectSection() {
        for display in [SlackModePresentation.Display.full, .fullLive] {
            let folded = section(display)
            XCTAssertTrue(folded.isFolded)
            XCTAssertTrue(folded.showsFoldButton)
            XCTAssertFalse(section(display, expanded: true).isFolded, "Connect another workspace… opens it")
        }
        for display in [SlackModePresentation.Display.live, .off, .sharedApp] {
            XCTAssertFalse(section(display).isFolded)
            XCTAssertFalse(section(display).showsFoldButton)
        }
    }

    func testFullOpensFoldWhileIdleAndPortBusy() {
        let s = section(.full, portBusy: true)
        XCTAssertFalse(s.isFolded, "the busy line must be seen")
        XCTAssertNotNil(s.portBusyLine)
    }

    func testOrganizationRowsFromPolicy() {
        let apps = [
            ManagedPolicy.SlackApp(teamID: "T0ACME", clientID: "1111.2222"),
            ManagedPolicy.SlackApp(teamID: "T0BETA", clientID: "3333.4444"),
            ManagedPolicy.SlackApp(teamID: "T0GAMA", clientID: "5555.6666"),
            ManagedPolicy.SlackApp(teamID: "T0DELT", clientID: "7777.8888")
        ]
        let accounts = [
            connectAccount(team: "T0ACME", client: "1111.2222"), // connected with that client: no row
            connectAccount(team: "T0BETA", client: "9999.0000"), // another client (shared app): row stays
            connectAccount(team: "T0GAMA", client: "5555.6666", status: "removed"), // removed: row stays
            connectAccount(team: "T0DELT", client: "7777.8888", status: "error") // needs Re-login, still connected
        ]
        let rows = section(apps: apps, accounts: accounts).organizationRows
        XCTAssertEqual(rows.map(\.title), ["Workspace T0BETA", "Workspace T0GAMA"])
        XCTAssertEqual(rows.first?.target, SlackConnectTarget(teamID: "T0BETA", clientID: "3333.4444"))
        XCTAssertEqual(section(apps: nil).organizationRows, [], "no key, no rows")
    }

    /// A8: **Add Slack Workspace** only while the build has its own app; once
    /// it has none, **Connect another workspace…** (Full) or the open section
    /// is the way in.
    func testAddAccountFollowsBuiltinApp() {
        XCTAssertTrue(section(.full, builtinApp: true).showsAddAccount)
        for display in [SlackModePresentation.Display.full, .fullLive, .live, .off, .sharedApp] {
            XCTAssertFalse(section(display, builtinApp: false).showsAddAccount, "\(display)")
        }
        let full = section(.full, builtinApp: false)
        XCTAssertTrue(full.showsFoldButton)
        XCTAssertTrue(full.isFolded)
        XCTAssertEqual(full.foldButton, "Connect another workspace…")
        XCTAssertFalse(section(.sharedApp, builtinApp: false).isFolded, "the section is open on the shared app")
    }
}
