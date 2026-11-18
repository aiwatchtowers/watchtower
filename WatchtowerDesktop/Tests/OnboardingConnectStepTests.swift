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
    /// section; no connect flow keeps the Add sheet (unknown counts as having
    /// an app: `SlackAccountsViewModelTests.testFlagsReadFailureKeepsLast`).
    func testSlackWithoutBuiltinAppOpensConnectSection() {
        XCTAssertTrue(OnboardingConnectStepView.slackOpensConnectSection(builtinApp: false, hasConnectFlow: true))
        XCTAssertFalse(OnboardingConnectStepView.slackOpensConnectSection(builtinApp: true, hasConnectFlow: true))
        XCTAssertFalse(OnboardingConnectStepView.slackOpensConnectSection(builtinApp: false, hasConnectFlow: false))
    }
}
