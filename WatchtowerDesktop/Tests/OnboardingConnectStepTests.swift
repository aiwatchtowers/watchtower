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
        XCTAssertEqual(OnboardingConnectStepView.googleSheet(mail: true, calendar: false).daemonPolicy, .deferred)
        XCTAssertEqual(OnboardingConnectStepView.jiraSheet().daemonPolicy, .deferred)
    }

    func testGoogleSheetOpensWithTheGoalsScopes() {
        let mailOnly = OnboardingConnectStepView.googleSheet(mail: true, calendar: false)
        XCTAssertTrue(mailOnly.presetMail)
        XCTAssertFalse(mailOnly.presetCalendar)
        let calendarOnly = OnboardingConnectStepView.googleSheet(mail: false, calendar: true)
        XCTAssertFalse(calendarOnly.presetMail)
        XCTAssertTrue(calendarOnly.presetCalendar)
        let settings = AddGoogleAccountView()
        XCTAssertTrue(settings.presetMail && settings.presetCalendar, "Settings keeps both on")
    }

    func testGoogleSubtitleNamesTheScopes() {
        XCTAssertEqual(OnboardingConnectStepView.googleSubtitle(mail: true, calendar: false), "Mail · for work communication")
        XCTAssertEqual(OnboardingConnectStepView.googleSubtitle(mail: false, calendar: true), "Calendar · for meetings")
        XCTAssertEqual(OnboardingConnectStepView.googleSubtitle(mail: true, calendar: true),
                       "Mail and calendar · for work communication and meetings")
    }
}
