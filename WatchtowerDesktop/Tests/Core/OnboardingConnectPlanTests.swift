import XCTest
@testable import WatchtowerCore

final class OnboardingConnectPlanTests: XCTestCase {
    func testCardsFollowTheGoals() {
        XCTAssertEqual(OnboardingConnectPlan.sources(for: [.workCommunication]),
                       [.slack, .google(mail: true, calendar: false)])
        XCTAssertEqual(OnboardingConnectPlan.sources(for: [.meetings]), [.google(mail: false, calendar: true)])
        XCTAssertEqual(OnboardingConnectPlan.sources(for: [.tasksAndJira]), [.jira])
        XCTAssertEqual(OnboardingConnectPlan.sources(for: [.workCommunication, .meetings, .tasksAndJira, .development]),
                       [.slack, .google(mail: true, calendar: true), .jira])
    }

    /// Development alone needs no source; the route skips the step anyway.
    func testDevelopmentOnlyHasNoCards() {
        XCTAssertEqual(OnboardingConnectPlan.sources(for: [.development]), [])
        XCTAssertEqual(OnboardingConnectPlan.sources(for: []), [])
        XCTAssertTrue(OnboardingRoute(goals: [.development], hasSlackAccount: false).skips(.connect))
    }

    func testNewlyConnectedSlackAccount() {
        XCTAssertEqual(OnboardingConnectPlan.newlyConnected(before: [], after: [3]), 3)
        XCTAssertEqual(OnboardingConnectPlan.newlyConnected(before: [1], after: [1, 2]), 2)
        XCTAssertNil(OnboardingConnectPlan.newlyConnected(before: [1], after: [1]), "a cancelled sheet starts nothing")
        XCTAssertNil(OnboardingConnectPlan.newlyConnected(before: [], after: []))
    }
}
