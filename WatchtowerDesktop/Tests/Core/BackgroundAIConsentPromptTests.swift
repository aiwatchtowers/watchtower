import Foundation
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

    private struct NoRunner: CLIRunnerProtocol {
        func run(args: [String]) async throws -> Data { Data() }
    }

    @MainActor
    private func model() -> BackgroundAIConsentModel {
        BackgroundAIConsentModel(
            runner: NoRunner(), configPath: "config.yaml", agent: .claude, reserve: nil, pollMinutes: 15, backfillDays: 30
        )
    }

    @MainActor
    private func due(
        _ sheet: inout BackgroundAIConsentSheet,
        notes: Bool = false,
        unreadable: Bool = false,
        done: Bool = true,
        made: BackgroundAIConsentModel? = nil
    ) {
        let made = made ?? model()
        sheet.presentIfDue(onboardingDone: done, state: unanswered, configUnreadable: unreadable,
                           releaseNotesPending: notes) { made }
    }

    @MainActor
    func testUpgradeSheetOpensOncePerLaunch() {
        var sheet = BackgroundAIConsentSheet()
        due(&sheet)
        XCTAssertEqual(sheet.opened, .upgrade)
        XCTAssertNotNil(sheet.model)
        sheet.close()
        XCTAssertNil(sheet.model)
        due(&sheet)
        XCTAssertNil(sheet.opened, "once per launch")
    }

    @MainActor
    func testUpgradeSheetWaitsForReleaseNotesAndAReadableConfig() {
        var sheet = BackgroundAIConsentSheet()
        due(&sheet, notes: true)
        XCTAssertNil(sheet.opened, "never stacked on the release notes window")
        due(&sheet, unreadable: true)
        XCTAssertNil(sheet.opened, "the writer refuses an unreadable config.yaml")
        sheet.presentIfDue(onboardingDone: true, state: unanswered, configUnreadable: false,
                           releaseNotesPending: false) { nil }
        XCTAssertNil(sheet.opened, "a file unreadable at the re-read opens nothing")
        due(&sheet, done: false)
        XCTAssertNil(sheet.opened, "onboarding asks in its own step")
        due(&sheet)
        XCTAssertEqual(sheet.opened, .upgrade, "presented once nothing holds it")
    }

    @MainActor
    func testReEntryOpensOrShowsTheConfigError() {
        var sheet = BackgroundAIConsentSheet()
        XCTAssertEqual(sheet.present(configUnreadable: true) { self.model() }, .configError)
        XCTAssertNil(sheet.opened)
        XCTAssertTrue(sheet.showsConfigError)
        sheet.dismissConfigError()
        XCTAssertEqual(sheet.present(configUnreadable: false) { nil }, .configError, "unreadable at the re-read")
        sheet.dismissConfigError()
        XCTAssertEqual(sheet.present(configUnreadable: false) { self.model() }, .opened)
        XCTAssertEqual(sheet.opened, .reEntry)
    }

    /// A wanted sheet that never mounted is re-asserted with the same kind
    /// and model; a mounted one is only brought forward, never replaced.
    @MainActor
    func testReEntryRetriesOnlyAnUnmountedSheet() {
        var sheet = BackgroundAIConsentSheet()
        let first = model()
        due(&sheet, made: first)
        guard case let .retry(kind, held) = sheet.present(configUnreadable: false, makeModel: { self.model() }) else {
            return XCTFail("an unmounted sheet is retried")
        }
        XCTAssertEqual(kind, .upgrade)
        XCTAssertTrue(held === first)
        sheet.close()
        sheet.reopen(kind, model: held)
        XCTAssertEqual(sheet.opened, .upgrade)
        XCTAssertTrue(sheet.model === first)

        sheet.markMounted()
        XCTAssertEqual(sheet.present(configUnreadable: false) { self.model() }, .alreadyVisible)
        XCTAssertTrue(sheet.model === first, "a visible sheet keeps its model")
    }

    @MainActor
    func testFollowClosesPerDecision12() {
        var upgrade = BackgroundAIConsentSheet()
        due(&upgrade)
        upgrade.follow(unanswered)
        XCTAssertEqual(upgrade.opened, .upgrade)
        upgrade.follow(ownerPaused)
        XCTAssertNil(upgrade.opened, "answered in a terminal")

        var reEntry = BackgroundAIConsentSheet()
        reEntry.present(configUnreadable: false) { self.model() }
        reEntry.follow(ownerPaused)
        XCTAssertEqual(reEntry.opened, .reEntry)
        reEntry.follow(allowed)
        XCTAssertNil(reEntry.opened)
    }
}
