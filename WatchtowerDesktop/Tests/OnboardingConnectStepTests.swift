import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore

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

    /// Connecting Google means mail and calendar, whatever the goals (#740):
    /// the one sheet onboarding and Settings share opens with both checked.
    func testGoogleSheetOpensWithMailAndCalendarChecked() {
        XCTAssertTrue(AddGoogleAccountView.initialScopes.calendar)
        XCTAssertTrue(AddGoogleAccountView.initialScopes.gmail)
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
}
