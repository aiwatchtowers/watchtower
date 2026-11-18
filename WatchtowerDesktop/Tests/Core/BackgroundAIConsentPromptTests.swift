import XCTest
@testable import WatchtowerCore

final class BackgroundAIConsentPromptTests: XCTestCase {
    private typealias Prompt = BackgroundAIConsentPrompt
    private let unanswered = BackgroundAIConsent.resolve(answer: nil, policy: nil)
    private let ownerPaused = BackgroundAIConsent.resolve(answer: "paused", policy: nil)
    private let allowed = BackgroundAIConsent.resolve(answer: "allowed", policy: nil)
    private let orgAllowed = BackgroundAIConsent.resolve(answer: nil, policy: true)
    private let orgOff = BackgroundAIConsent.resolve(answer: nil, policy: false)

    func testClosesWhenAnsweredElsewhere() {
        XCTAssertTrue(Prompt.shouldClose(opened: .upgrade, state: ownerPaused))
        XCTAssertFalse(Prompt.shouldClose(opened: .upgrade, state: unanswered))
        XCTAssertFalse(Prompt.shouldClose(opened: .reEntry, state: ownerPaused))
        XCTAssertTrue(Prompt.shouldClose(opened: .reEntry, state: allowed))
    }

    func testShownOnceUntilAnsweredAfterOnboarding() {
        XCTAssertTrue(Prompt.shouldPresent(onboardingDone: true, state: unanswered))
        XCTAssertFalse(Prompt.shouldPresent(onboardingDone: false, state: unanswered))
        XCTAssertFalse(Prompt.shouldPresent(onboardingDone: true, state: ownerPaused))
        XCTAssertFalse(Prompt.shouldPresent(onboardingDone: true, state: orgAllowed))
        XCTAssertFalse(Prompt.shouldPresent(onboardingDone: true, state: orgOff))
    }

    // MARK: - The sheet's open state

    func testUpgradeSheetOpensOncePerLaunch() {
        var sheet = BackgroundAIConsentSheet()
        sheet.presentIfDue(onboardingDone: true, state: unanswered, configUnreadable: false, releaseNotesOpen: false)
        XCTAssertEqual(sheet.opened, .upgrade)
        sheet.close()
        sheet.presentIfDue(onboardingDone: true, state: unanswered, configUnreadable: false, releaseNotesOpen: false)
        XCTAssertNil(sheet.opened, "once per launch")
    }

    func testUpgradeSheetWaitsForReleaseNotesAndAReadableConfig() {
        var sheet = BackgroundAIConsentSheet()
        sheet.presentIfDue(onboardingDone: true, state: unanswered, configUnreadable: false, releaseNotesOpen: true)
        XCTAssertNil(sheet.opened, "never stacked on the release notes window")
        sheet.presentIfDue(onboardingDone: true, state: unanswered, configUnreadable: true, releaseNotesOpen: false)
        XCTAssertNil(sheet.opened, "the writer refuses an unreadable config.yaml")
        sheet.presentIfDue(onboardingDone: false, state: unanswered, configUnreadable: false, releaseNotesOpen: false)
        XCTAssertNil(sheet.opened, "onboarding asks in its own step")
        sheet.presentIfDue(onboardingDone: true, state: unanswered, configUnreadable: false, releaseNotesOpen: false)
        XCTAssertEqual(sheet.opened, .upgrade, "presented once nothing holds it")
    }

    func testReEntryOpensOrShowsTheConfigError() {
        var sheet = BackgroundAIConsentSheet()
        sheet.present(configUnreadable: true)
        XCTAssertNil(sheet.opened)
        XCTAssertTrue(sheet.showsConfigError)
        sheet.dismissConfigError()
        XCTAssertFalse(sheet.showsConfigError)
        sheet.present(configUnreadable: false)
        XCTAssertEqual(sheet.opened, .reEntry)
    }

    func testFollowClosesPerDecision12() {
        var upgrade = BackgroundAIConsentSheet()
        upgrade.presentIfDue(onboardingDone: true, state: unanswered, configUnreadable: false, releaseNotesOpen: false)
        upgrade.follow(unanswered)
        XCTAssertEqual(upgrade.opened, .upgrade)
        upgrade.follow(ownerPaused)
        XCTAssertNil(upgrade.opened, "answered in a terminal")

        var reEntry = BackgroundAIConsentSheet()
        reEntry.present(configUnreadable: false)
        reEntry.follow(ownerPaused)
        XCTAssertEqual(reEntry.opened, .reEntry)
        reEntry.follow(allowed)
        XCTAssertNil(reEntry.opened)
    }
}
