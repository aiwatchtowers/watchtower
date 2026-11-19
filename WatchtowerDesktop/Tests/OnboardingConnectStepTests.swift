import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The Connect step opens the Settings sheets and removes accounts without
/// restarting the daemon mid-setup.
@MainActor
final class OnboardingConnectStepTests: XCTestCase {
    func testEverySheetAndRemoveIsDeferred() {
        XCTAssertEqual(OnboardingConnectStepView.daemonPolicy, .deferred)
        XCTAssertEqual(OnboardingConnectStepView.slackSheet().daemonPolicy, .deferred)
        XCTAssertEqual(OnboardingConnectStepView.googleSheet().daemonPolicy, .deferred)
        XCTAssertEqual(OnboardingConnectStepView.jiraSheet().daemonPolicy, .deferred)
    }

    /// Connecting Google means every service its client may ask for,
    /// whatever the goals (#740): the one sheet onboarding and Settings share
    /// opens with them checked. Watchtower's shared app asks for Calendar
    /// only (#1887 D11), so on the public build Gmail starts off; a flavored
    /// build's client asks for both.
    func testGoogleSheetOpensWithEveryOfferedServiceChecked() {
        let shared = AddGoogleAccountView.initialScopes(offersGmail: false)
        XCTAssertTrue(shared.calendar)
        XCTAssertFalse(shared.gmail)
        let flavored = AddGoogleAccountView.initialScopes(offersGmail: true)
        XCTAssertTrue(flavored.calendar)
        XCTAssertTrue(flavored.gmail)
        // The test bundle is flavorless: the onboarding sheet is the shared path.
        XCTAssertFalse(OnboardingConnectStepView.googleSheet().offersGmail)
    }

    /// Plan B A13: with no Slack app in the build the card opens the connect
    /// section; flags still unknown after the card's read prefer it too; no
    /// connect flow keeps the Add sheet.
    func testSlackWithoutBuiltinAppOpensConnectSection() {
        let none = SlackAccountsDocument(builtinApp: false, accounts: [])
        let builtin = SlackAccountsDocument(builtinApp: true, accounts: [])
        XCTAssertTrue(OnboardingConnectStepView.slackOpensConnectSection(flags: none, hasConnectFlow: true))
        XCTAssertFalse(OnboardingConnectStepView.slackOpensConnectSection(flags: builtin, hasConnectFlow: true))
        XCTAssertTrue(OnboardingConnectStepView.slackOpensConnectSection(flags: nil, hasConnectFlow: true),
                      "unknown: the connect section works on every build")
        XCTAssertFalse(OnboardingConnectStepView.slackOpensConnectSection(flags: none, hasConnectFlow: false))
        XCTAssertFalse(OnboardingConnectStepView.slackOpensConnectSection(flags: nil, hasConnectFlow: false))
    }

    /// Fix round 1: an About link clicked during onboarding opens the Slack
    /// sheet (its confirm) when it is closed.
    func testLinkDuringOnboardingOpensTheSlackSheet() {
        typealias View = OnboardingConnectStepView
        XCTAssertEqual(View.sheet(nil, flowShowsSheet: true), .slackConnect)
        XCTAssertNil(View.sheet(nil, flowShowsSheet: false))
        XCTAssertEqual(View.sheet(.slackConnect, flowShowsSheet: true), .slackConnect)
    }

    /// Fix round 2: a link that came while another source's sheet was up
    /// shows once that sheet closes (the view re-checks on every sheet change).
    func testLinkWaitsForAnotherSheetToClose() {
        typealias View = OnboardingConnectStepView
        XCTAssertEqual(View.sheet(.google, flowShowsSheet: true), .google, "never over another sheet")
        XCTAssertEqual(View.sheet(nil, flowShowsSheet: true), .slackConnect, "the Google sheet closed")
    }

    /// Fix round 2: a sheet that opened during the card's flags read (a
    /// link's confirm) is not replaced by the card's choice.
    func testFlagsReadKeepsASheetThatOpenedMeanwhile() {
        typealias View = OnboardingConnectStepView
        XCTAssertEqual(View.sheet(.slackConnect, afterFlagsRead: .slack), .slackConnect)
        XCTAssertEqual(View.sheet(nil, afterFlagsRead: .slack), .slack)
    }

    /// Fix round 3: closing the Slack sheet over a finished flow dismisses
    /// the flow (no reopen of the same result); another sheet closing
    /// retries a queued link instead.
    func testClosingTheSlackSheetDismissesItsFinishedFlow() {
        typealias View = OnboardingConnectStepView
        XCTAssertTrue(View.closingDismissesFlow(from: .slackConnect, to: nil))
        XCTAssertFalse(View.closingDismissesFlow(from: .google, to: nil), "a different sheet: retry the queued link")
        XCTAssertFalse(View.closingDismissesFlow(from: nil, to: .slackConnect))

        let host = SlackConnectListenerHost(streamer: FakeCLILineStream())
        let flow = SlackConnectFlowModel(host: host)
        host.onEvent?(.link(flow: "f1", teamID: "T0ACME", clientID: "1111.2222"))
        flow.confirm()
        host.onEvent?(.failed(flow: "f1", reason: .denied, message: ""))
        XCTAssertTrue(flow.showsSheet, "a failed result")
        flow.dismiss() // what the close does
        XCTAssertFalse(flow.showsSheet)
        XCTAssertNil(View.sheet(nil, flowShowsSheet: flow.showsSheet), "the result does not reopen")
    }
}
