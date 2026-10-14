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
}
