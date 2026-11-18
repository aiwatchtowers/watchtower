import Foundation
import XCTest
@testable import WatchtowerCore
import WatchtowerTestSupport

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
    /// and a model rebuilt from the saved config (the first was never seen);
    /// a mounted one is only brought forward, never replaced.
    @MainActor
    func testReEntryRetriesOnlyAnUnmountedSheet() {
        var sheet = BackgroundAIConsentSheet()
        let first = model()
        due(&sheet, made: first)
        let rebuilt = model()
        guard case let .retry(kind, held) = sheet.present(configUnreadable: false, makeModel: { rebuilt }) else {
            return XCTFail("an unmounted sheet is retried")
        }
        XCTAssertEqual(kind, .upgrade)
        XCTAssertTrue(held === rebuilt, "rebuilt from the saved config, not the unseen model")
        sheet.close()
        sheet.reopen(kind, model: held)
        XCTAssertEqual(sheet.opened, .upgrade)
        XCTAssertTrue(sheet.model === rebuilt)

        sheet.markMounted()
        XCTAssertEqual(sheet.present(configUnreadable: false) { self.model() }, .alreadyVisible)
        XCTAssertTrue(sheet.model === rebuilt, "a visible sheet keeps its model")
    }

    /// An unmounted retry whose config became unreadable shows the error.
    @MainActor
    func testUnmountedRetryWithAnUnreadableConfigShowsTheError() {
        var sheet = BackgroundAIConsentSheet()
        due(&sheet)
        XCTAssertEqual(sheet.present(configUnreadable: false) { nil }, .configError)
        XCTAssertNil(sheet.opened)
        XCTAssertTrue(sheet.showsConfigError)
    }

    /// #1886 (C4): the screen never discloses without the provider catalog
    /// (the plan and usage-limit lines come from it). Unread, the upgrade
    /// sheet waits, a re-entry asks the caller to read it, and the caller's
    /// failed read shows Try again; no model is made meanwhile.
    @MainActor
    func testNothingOpensBeforeTheCatalogIsRead() {
        var made = 0
        var sheet = BackgroundAIConsentSheet()
        sheet.presentIfDue(onboardingDone: true, state: unanswered, configUnreadable: false,
                           releaseNotesPending: false, catalogLoaded: false) { made += 1; return self.model() }
        XCTAssertNil(sheet.opened, "the upgrade sheet waits for the catalog")
        XCTAssertEqual(sheet.present(configUnreadable: false, catalogLoaded: false) { made += 1; return self.model() },
                       .needsCatalog)
        XCTAssertNil(sheet.opened)
        XCTAssertEqual(made, 0)
        sheet.showCatalogRetry()
        XCTAssertTrue(sheet.showsCatalogRetry)
        sheet.dismissCatalogRetry()
        XCTAssertEqual(sheet.present(configUnreadable: false, catalogLoaded: true) { self.model() }, .opened)
        XCTAssertEqual(sheet.opened, .reEntry)

        var upgrade = BackgroundAIConsentSheet()
        upgrade.presentIfDue(onboardingDone: true, state: unanswered, configUnreadable: false,
                             releaseNotesPending: false, catalogLoaded: true) { self.model() }
        XCTAssertEqual(upgrade.opened, .upgrade, "once read, the upgrade sheet opens")
    }

    /// The onboarding step offers Try again while the catalog is unread, and
    /// shows the screen once a re-read finds it.
    @MainActor
    func testStepLoadWaitsForTheCatalog() {
        var load = BackgroundAIConsentStepLoad.pending
        load.load(catalogLoaded: false) { XCTFail("no model before the catalog"); return nil }
        guard case .catalogUnavailable = load else { return XCTFail("catalogUnavailable") }
        load.load(catalogLoaded: true) { self.model() }
        guard case .ready = load else { return XCTFail("ready after the catalog read") }
    }

    /// Onboarding's step re-reads config.yaml after `.unreadable` and never
    /// replaces a loaded model.
    @MainActor
    func testStepLoadRereadsAndKeepsALoadedModel() {
        var load = BackgroundAIConsentStepLoad.pending
        load.load { nil }
        guard case .unreadable = load else { return XCTFail("unreadable") }
        let fixed = model()
        load.load { fixed }
        guard case .ready(let shown) = load else { return XCTFail("ready after the re-read") }
        XCTAssertTrue(shown === fixed)
        load.load { self.model() }
        guard case .ready(let kept) = load else { return XCTFail("still ready") }
        XCTAssertTrue(kept === fixed, "a loaded model is never replaced")
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
