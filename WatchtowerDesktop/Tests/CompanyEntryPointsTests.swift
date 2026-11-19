import GRDB
import SwiftUI
import ViewInspector
import WatchtowerCore
import WatchtowerTestSupport
import XCTest
@testable import WatchtowerDesktop

/// The ways into the company setup the screens spec lists (§2.1) beyond the
/// Companies zone — the Connect… menu's last entries and Jira's empty state
/// — and Email's **Connect Gmail**, which goes where Gmail can connect now
/// that the shared Google app asks for Calendar only (#1887 D11).
@MainActor
final class CompanyEntryPointsTests: XCTestCase {
    private typealias Pres = CompanyConnectionsPresentation

    private static let acmeWithGoogle = #"{"companies":[{"slug":"acme","company":"Acme","forced":false,"personal":false,"#
        + #""vendors":{"google":{"client_id":"goo-1"}}}],"errors":[],"draft":{"state":"none"}}"#
    private static let none = #"{"companies":[],"errors":[],"draft":{"state":"none"}}"#
    private static let damaged = #"{"companies":[],"errors":[{"file":"acme.json","error":"bad json"}],"#
        + #""draft":{"state":"none"}}"#

    // MARK: Connect… menu

    func testConnectMenuEndsWithTheCompanyEntries() throws {
        var pressed: [CompaniesZoneState.Action] = []
        let view = ConnectionsOverviewContent(
            summaries: [ConnectionSummary(service: .slack, accounts: [], blocked: false)],
            companies: EmptyView(),
            onCompanyAction: { pressed.append($0) },
            onOpen: { _ in }
        )
        let menu = try view.inspect().find(ViewType.Menu.self)
        XCTAssertNoThrow(try menu.find(button: "Slack"))
        try menu.find(button: "Set up for my company").tap()
        try menu.find(button: "Connect with a company code").tap()
        XCTAssertEqual(pressed, [.setUpForCompany, .connectWithCode])
    }

    /// Without the company actions (a caller that has no zone) the menu lists services only.
    func testConnectMenuWithoutCompanyActions() throws {
        let view = ConnectionsOverviewContent(summaries: [ConnectionSummary(service: .slack, accounts: [], blocked: false)]) { _ in }
        XCTAssertThrowsError(try view.inspect().find(ViewType.Menu.self).find(button: "Set up for my company"))
    }

    /// **Set up for my company** opens the wizard page; **Connect with a
    /// company code** opens the zone's field on the overview — the same
    /// paths the zone's own buttons take.
    func testConnectMenuEntriesRoute() {
        let (appState, _) = LinearConnectionDetailTests.wired()
        appState.performConnectMenuCompanyAction(.setUpForCompany)
        XCTAssertEqual(appState.selectedDestination, .connections)
        XCTAssertEqual(appState.selectedConnection, .companySetup)

        appState.performConnectMenuCompanyAction(.connectWithCode)
        XCTAssertNil(appState.selectedConnection, "the overview, where the field is")
        XCTAssertTrue(appState.companiesZone.codeFieldOpen)
    }

    // MARK: Jira empty state

    func testJiraEmptyStateOpensTheWizard() async throws {
        let (appState, _) = LinearConnectionDetailTests.wired()
        let (pool, path) = try TestDatabase.createPool()
        addTeardownBlock { TestDatabase.cleanup(path: path) }
        let vm = JiraAccountsViewModel(dbPool: pool, daemon: FakeDaemonRestarter()) { nil }
        appState.jiraAccountsViewModel = vm
        await vm.refreshAsync()

        let view = JiraConnectionDetail().environment(appState)
        XCTAssertNoThrow(try view.inspect().find(text: Pres.jiraEmpty))
        try view.inspect().find(button: CompaniesZoneState.Action.setUpForCompany.title).tap()
        XCTAssertEqual(appState.selectedConnection, .companySetup)
    }

    // MARK: Connect Gmail

    /// No company has a Google app: the own Google project page in the Google detail.
    func testConnectGmailOpensTheOwnProjectPage() async {
        let (appState, fake) = LinearConnectionDetailTests.wired()
        fake.enqueue(.init(lines: [Self.none]))
        await appState.companiesZone.reload()

        appState.connectGmail()
        XCTAssertEqual(appState.selectedDestination, .connections)
        XCTAssertEqual(appState.selectedConnection, .google)
        XCTAssertTrue(appState.ownGoogleProject.isOpen)
    }

    /// A stored company with a Google app: the Google detail, where its row's
    /// Connect is the way; no own project page over it.
    func testConnectGmailWithACompanyGoogleAppOpensTheDetail() async {
        let (appState, fake) = LinearConnectionDetailTests.wired()
        fake.enqueue(.init(lines: [Self.acmeWithGoogle]))
        await appState.companiesZone.reload()

        appState.connectGmail()
        XCTAssertEqual(appState.selectedConnection, .google)
        XCTAssertFalse(appState.ownGoogleProject.isOpen)
    }

    /// Failure paths: company files never read, `company list` failing, or a
    /// damaged company file — whether a company has a Google app is unknown,
    /// so the detail (which shows the read state) opens, never the own page.
    func testConnectGmailWithUnknownCompaniesOpensTheDetail() async {
        let (unread, _) = LinearConnectionDetailTests.wired()
        unread.connectGmail()
        XCTAssertEqual(unread.selectedConnection, .google)
        XCTAssertFalse(unread.ownGoogleProject.isOpen)

        let (failed, failedFake) = LinearConnectionDetailTests.wired()
        failedFake.enqueue(.init(lines: [], exitCode: 1))
        await failed.companiesZone.reload()
        XCTAssertNotNil(failed.companiesZone.listError)
        failed.connectGmail()
        XCTAssertFalse(failed.ownGoogleProject.isOpen)

        let (broken, brokenFake) = LinearConnectionDetailTests.wired()
        brokenFake.enqueue(.init(lines: [Self.damaged]))
        await broken.companiesZone.reload()
        broken.connectGmail()
        XCTAssertFalse(broken.ownGoogleProject.isOpen)
    }

    /// Own projects locked (§5.4): the detail, whose empty state offers the company code.
    func testConnectGmailUnderTheOwnProjectLockOpensTheDetail() async {
        let (appState, fake) = LinearConnectionDetailTests.wired(policy: ["AllowOwnGoogleProject": false])
        fake.enqueue(.init(lines: [Self.none]))
        await appState.companiesZone.reload()

        appState.connectGmail()
        XCTAssertEqual(appState.selectedConnection, .google)
        XCTAssertFalse(appState.ownGoogleProject.isOpen)
    }

    /// The Email sheet's Gmail card on the (flavorless) test build: the
    /// card says where Gmail connects; Connect Gmail leaves for the Google
    /// detail instead of opening the Calendar-only sheet.
    func testEmailGmailCardRoutesAwayFromTheSharedSheet() async throws {
        let (appState, fake) = LinearConnectionDetailTests.wired()
        fake.enqueue(.init(lines: [Self.none]))
        await appState.companiesZone.reload()
        XCTAssertFalse(appState.sharedGoogleOffersGmail)

        let view = AddEmailAccountView().environment(appState)
        XCTAssertNoThrow(try view.inspect().find(text: Pres.gmailCardLine(offersGmail: false, locks: [])))
        try view.inspect().find(button: Pres.connectGmail).tap()
        XCTAssertEqual(appState.selectedConnection, .google)
        XCTAssertTrue(appState.ownGoogleProject.isOpen)
    }
}
