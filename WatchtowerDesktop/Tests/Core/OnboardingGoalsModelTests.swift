import XCTest
@testable import WatchtowerCore

@MainActor
final class OnboardingGoalsModelTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var spy = Spy()

    /// What the model's injected closures saw and should answer.
    @MainActor
    private final class Spy {
        var calls: [String] = []
        var cliResult: OnboardingCLICheck = .ready(provider: "claude")
        var workspaceError: Error?
        var languageError: Error?
        var featuresFailure: String?
        var appliedSelection: OnboardingFeatureSelection?
        var historyUnset = false
        var featuresChanged = false
    }

    private struct Failure: LocalizedError {
        let errorDescription: String?
    }

    override func setUp() {
        super.setUp()
        suiteName = "OnboardingGoalsModelTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        spy = Spy()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeModel(
        systemLanguage: String = "Russian",
        checkCLI: (() async -> OnboardingCLICheck)? = nil
    ) -> OnboardingGoalsModel {
        let spy = self.spy
        return OnboardingGoalsModel(
            defaults: defaults,
            systemLanguage: systemLanguage,
            checkCLI: checkCLI ?? { spy.cliResult },
            actions: OnboardingGoalsActions(
                initWorkspace: {
                    spy.calls.append("workspace init")
                    if let error = spy.workspaceError { throw error }
                },
                setLanguage: {
                    spy.calls.append("language \($0)")
                    if let error = spy.languageError { throw error }
                },
                applyFeatures: {
                    spy.calls.append("features")
                    spy.appliedSelection = $0
                    return (spy.featuresFailure, spy.featuresChanged)
                },
                historyDepthUnset: { spy.historyUnset },
                setHistoryDepth: { spy.calls.append("history \($0)") }
            )
        )
    }

    private func readyModel() async -> OnboardingGoalsModel {
        let model = makeModel()
        await model.prepare(configuredLanguage: nil)
        return model
    }

    // MARK: - Defaults

    func testDefaultGoalsAreAllButMeetings() {
        let model = makeModel()
        XCTAssertEqual(model.selection.goals, [.workCommunication, .tasksAndJira, .development])
        XCTAssertFalse(model.selection.isCustomized)
        XCTAssertEqual(model.language, "Russian")
    }

    func testConfiguredLanguageWinsOnceOverTheMacDefault() async {
        let model = makeModel()
        await model.prepare(configuredLanguage: "Polish")
        XCTAssertEqual(model.language, "Polish")
        model.language = "German"
        await model.prepare(configuredLanguage: "Polish")
        XCTAssertEqual(model.language, "German", "a re-appearing step must not undo the owner's pick")
    }

    func testBlankConfiguredLanguageKeepsTheMacDefault() async {
        let model = makeModel()
        await model.prepare(configuredLanguage: "  ")
        XCTAssertEqual(model.language, "Russian")
    }

    // MARK: - Continue gate per CLI check

    func testContinueIsBlockedWhileChecking() {
        let model = makeModel()
        XCTAssertEqual(model.cliCheck, .checking)
        XCTAssertFalse(model.canContinue)
    }

    func testContinueUnlocksWhenTheCLIIsReady() async {
        let model = await readyModel()
        XCTAssertEqual(model.cliCheck, .ready(provider: "claude"))
        XCTAssertTrue(model.canContinue)
    }

    func testContinueStaysBlockedWhenTheCLIFails() async {
        spy.cliResult = .failed("claude: command not found")
        let model = await readyModel()
        XCTAssertEqual(model.cliCheck, .failed("claude: command not found"))
        XCTAssertFalse(model.canContinue)
        let route = await model.submit(hasSlackAccount: false)
        XCTAssertNil(route)
        XCTAssertEqual(spy.calls, [], "a blocked Continue writes nothing")
    }

    func testCheckAgainUnlocksAfterTheOwnerFixedTheCLI() async {
        spy.cliResult = .failed("not signed in")
        let model = await readyModel()
        spy.cliResult = .ready(provider: "codex")
        await model.runCLICheck()
        XCTAssertTrue(model.canContinue)
    }

    func testPassedCheckIsNotRerunOnReappear() async {
        let model = await readyModel()
        spy.cliResult = .failed("would fail now")
        await model.prepare(configuredLanguage: nil)
        XCTAssertEqual(model.cliCheck, .ready(provider: "claude"))
    }

    // MARK: - Continue writes

    func testContinueWithoutSlackInitsWorkspaceThenLanguageThenFeatures() async {
        let model = await readyModel()
        model.language = "Polish"
        let route = await model.submit(hasSlackAccount: false)
        XCTAssertEqual(spy.calls, ["workspace init", "language Polish", "features"])
        XCTAssertEqual(spy.appliedSelection?.enabledFeatureIDs,
                       OnboardingFeaturePlan.enabledFeatureIDs(for: [.workCommunication, .tasksAndJira, .development]))
        XCTAssertEqual(route, OnboardingRoute(goals: [.workCommunication, .tasksAndJira, .development], hasSlackAccount: false))
        XCTAssertNil(model.continueError)
    }

    func testContinueWithSlackSkipsWorkspaceInit() async {
        let model = await readyModel()
        _ = await model.submit(hasSlackAccount: true)
        XCTAssertEqual(spy.calls, ["language Russian", "features"])
    }

    func testWorkspaceInitRunsExactlyOnceAcrossContinues() async {
        let model = await readyModel()
        _ = await model.submit(hasSlackAccount: false)
        _ = await model.submit(hasSlackAccount: false)
        XCTAssertEqual(spy.calls.filter { $0 == "workspace init" }.count, 1)
        XCTAssertEqual(spy.calls.filter { $0 == "features" }.count, 2)
    }

    func testFailedWorkspaceInitStopsAndIsRetried() async {
        spy.workspaceError = Failure(errorDescription: "disk full")
        let model = await readyModel()
        let route = await model.submit(hasSlackAccount: false)
        XCTAssertNil(route)
        XCTAssertEqual(spy.calls, ["workspace init"])
        XCTAssertEqual(model.continueError, "Could not create the workspace: disk full")

        spy.workspaceError = nil
        let retried = await model.submit(hasSlackAccount: false)
        XCTAssertNotNil(retried)
        XCTAssertEqual(spy.calls, ["workspace init", "workspace init", "language Russian", "features"])
        XCTAssertNil(model.continueError)
    }

    func testFailedLanguageWriteStopsBeforeFeatures() async {
        spy.languageError = Failure(errorDescription: "config locked")
        let model = await readyModel()
        let route = await model.submit(hasSlackAccount: true)
        XCTAssertNil(route)
        XCTAssertEqual(spy.calls, ["language Russian"])
        XCTAssertEqual(model.continueError, "Could not save the assistant language: config locked")
    }

    /// `applySelection` returning false must not advance: the error shows
    /// and the goals are not saved as the route.
    func testFailedFeatureApplyDoesNotAdvance() async {
        spy.featuresFailure = "features enable tracks: exit 1"
        let model = await readyModel()
        model.toggle(.meetings)
        let route = await model.submit(hasSlackAccount: true)
        XCTAssertNil(route)
        XCTAssertEqual(model.continueError, "features enable tracks: exit 1")
        XCTAssertFalse(model.isContinuing)
        XCTAssertEqual(model.savedGoals, OnboardingGoalsModel.defaultGoals)
        XCTAssertNil(defaults.stringArray(forKey: OnboardingGoalsModel.goalsKey))
    }

    func testCustomizedSelectionIsWhatGetsApplied() async {
        let model = await readyModel()
        model.selection.setFeature("ideas", enabled: false)
        _ = await model.submit(hasSlackAccount: true)
        XCTAssertEqual(spy.appliedSelection?.isEnabled("ideas"), false)
        XCTAssertEqual(spy.appliedSelection?.isEnabled("tracks"), true)
    }

    /// Zero goals is allowed and behaves like Development only: Connect is
    /// skipped.
    func testZeroGoalsContinuesAsDevelopmentOnly() async {
        let model = await readyModel()
        model.selection.goals = []
        let route = await model.submit(hasSlackAccount: false)
        XCTAssertEqual(route?.step(after: .purpose), .complete)
        XCTAssertEqual(spy.appliedSelection?.enabledFeatureIDs, OnboardingFeaturePlan.alwaysOnFeatureIDs)
    }

    // MARK: - Saved goals (route of a relaunch, the indicator)

    func testSuccessfulContinuePersistsTheGoalsForTheNextLaunch() async {
        let model = await readyModel()
        model.selection.goals = [.development]
        _ = await model.submit(hasSlackAccount: false)

        let relaunched = makeModel()
        XCTAssertEqual(relaunched.savedGoals, [.development])
        XCTAssertEqual(relaunched.selection.goals, [.development])
        XCTAssertTrue(relaunched.route(hasSlackAccount: false).skips(.connect))
    }

    func testIndicatorRouteDoesNotFollowLiveCheckboxes() {
        let model = makeModel()
        let before = model.route(hasSlackAccount: true)
        model.selection.goals = [.development]
        XCTAssertEqual(model.route(hasSlackAccount: true), before)
    }

    func testUnknownPersistedGoalIsIgnored() {
        defaults.set(["meetings", "teleportation"], forKey: OnboardingGoalsModel.goalsKey)
        XCTAssertEqual(makeModel().savedGoals, [.meetings])
    }

    // MARK: - One check at a time, rerun

    /// A CLI check the test releases by hand.
    @MainActor
    private final class GatedCheck {
        var calls = 0
        private var waiting: [CheckedContinuation<OnboardingCLICheck, Never>] = []

        func check() async -> OnboardingCLICheck {
            calls += 1
            return await withCheckedContinuation { waiting.append($0) }
        }

        func release(_ index: Int, with result: OnboardingCLICheck) {
            waiting[index].resume(returning: result)
        }

        var pending: Int { waiting.count }
    }

    private func yieldALot() async {
        for _ in 0..<10 { await Task.yield() }
    }

    /// The step re-appearing (Goals ↔ Customize) or Check again while a
    /// check runs joins it: one `ai test`.
    func testNoSecondCheckWhileOneIsInFlight() async {
        let gate = GatedCheck()
        let model = makeModel { await gate.check() }
        let first = Task { await model.prepare(configuredLanguage: nil) }
        await yieldALot()
        let second = Task { await model.prepare(configuredLanguage: nil) }
        let third = Task { await model.runCLICheck() }
        await yieldALot()
        XCTAssertEqual(gate.calls, 1)

        gate.release(0, with: .ready(provider: "claude"))
        await first.value
        await second.value
        await third.value
        XCTAssertEqual(model.cliCheck, .ready(provider: "claude"))
    }

    /// A failed check is not rerun by the step re-appearing; Check again
    /// runs it.
    func testReappearingDoesNotRerunAFailedCheck() async {
        spy.cliResult = .failed("not signed in")
        let calls = Counter()
        let model = makeModel { [spy] in
            calls.value += 1
            return spy.cliResult
        }
        await model.prepare(configuredLanguage: nil)
        await model.prepare(configuredLanguage: nil)
        XCTAssertEqual(calls.value, 1)
        await model.runCLICheck()
        XCTAssertEqual(calls.value, 2)
    }

    @MainActor
    private final class Counter {
        var value = 0
    }

    /// A check started before "Run setup again" finishes after the new one:
    /// its result is dropped.
    func testStaleCheckResultIsDropped() async {
        let gate = GatedCheck()
        let model = makeModel { await gate.check() }
        let stale = Task { await model.prepare(configuredLanguage: nil) }
        await yieldALot()

        model.prepareForRerun()
        let fresh = Task { await model.prepare(configuredLanguage: nil) }
        await yieldALot()
        XCTAssertEqual(gate.pending, 2)

        gate.release(1, with: .failed("claude: not signed in"))
        await fresh.value
        gate.release(0, with: .ready(provider: "claude"))
        await stale.value
        XCTAssertEqual(model.cliCheck, .failed("claude: not signed in"))
    }

    func testPrepareForRerunResetsTheTransientState() async {
        spy.featuresFailure = "boom"
        let model = await readyModel()
        await model.prepare(configuredLanguage: "Polish")
        _ = await model.submit(hasSlackAccount: true)
        model.isCustomizingFeatures = true
        model.toggle(.meetings)

        model.prepareForRerun()

        XCTAssertEqual(model.cliCheck, .checking)
        XCTAssertNil(model.continueError)
        XCTAssertFalse(model.isCustomizingFeatures)
        XCTAssertTrue(model.selection.goals.contains(.meetings), "the goals stay")
        await model.prepare(configuredLanguage: "German")
        XCTAssertEqual(model.language, "German", "the configured language is adopted again")
        XCTAssertEqual(model.cliCheck, .ready(provider: "claude"), "the CLI is checked again")
    }

    // MARK: - History depth

    /// A config with no history depth gets the old onboarding's default,
    /// written after the workspace exists; one that has it is left alone.
    func testUnsetHistoryDepthGetsTheOldDefault() async {
        spy.historyUnset = true
        let model = await readyModel()
        _ = await model.submit(hasSlackAccount: false)
        XCTAssertEqual(spy.calls, ["workspace init", "history 3", "language Russian", "features"])
    }

    func testSetHistoryDepthIsLeftAlone() async {
        let model = await readyModel()
        _ = await model.submit(hasSlackAccount: false)
        XCTAssertFalse(spy.calls.contains { $0.hasPrefix("history") })
    }

    // MARK: - Run setup again

    /// A re-run with no change writes no language (and the features apply
    /// as a no-op — `FeatureManagerServiceTests`).
    func testRerunWithoutChangesWritesNoLanguage() async {
        let model = makeModel()
        let enabled = OnboardingFeaturePlan.enabledFeatureIDs(for: [.workCommunication])
        model.seedForRerun(enabledFeatureIDs: enabled, language: "Polish")
        await model.prepare(configuredLanguage: "German")
        XCTAssertEqual(model.language, "Polish", "the seeded config language is kept")

        _ = await model.submit(hasSlackAccount: true)

        XCTAssertEqual(spy.calls, ["features"])
        XCTAssertEqual(spy.appliedSelection?.enabledFeatureIDs, enabled)
    }

    func testRerunWithANewLanguageWritesIt() async {
        let model = makeModel()
        model.seedForRerun(enabledFeatureIDs: [], language: "Polish")
        await model.prepare(configuredLanguage: nil)
        model.language = "German"
        _ = await model.submit(hasSlackAccount: true)
        XCTAssertEqual(spy.calls, ["language German", "features"])
    }

    /// The reverse mapping: goals whose features are on; the saved goals win
    /// among equal combinations; a hand-toggled set is "customized".
    func testCurrentSelectionMapsBackToGoals() {
        let wcTasks = OnboardingFeaturePlan.enabledFeatureIDs(for: [.workCommunication, .tasksAndJira])
        let seeded = OnboardingFeatureSelection.current(
            enabledIDs: wcTasks, savedGoals: [.workCommunication, .tasksAndJira, .development]
        )
        XCTAssertEqual(seeded.goals, [.workCommunication, .tasksAndJira, .development])
        XCTAssertFalse(seeded.isCustomized)

        let fromNothing = OnboardingFeatureSelection.current(enabledIDs: wcTasks, savedGoals: [])
        XCTAssertEqual(fromNothing.goals, [.workCommunication, .tasksAndJira], "no extra goal without a reason")
        XCTAssertFalse(fromNothing.isCustomized)

        let devOnly = OnboardingFeatureSelection.current(
            enabledIDs: OnboardingFeaturePlan.alwaysOnFeatureIDs, savedGoals: [.development]
        )
        XCTAssertEqual(devOnly.goals, [.development])
    }

    func testHandToggledSetIsCustomized() {
        var enabled = OnboardingFeaturePlan.enabledFeatureIDs(for: [.workCommunication])
        enabled.remove("ideas")
        enabled.insert("memory")
        enabled.insert("not-managed")
        let seeded = OnboardingFeatureSelection.current(enabledIDs: enabled, savedGoals: [.development])
        XCTAssertTrue(seeded.isCustomized)
        XCTAssertTrue(seeded.goals.contains(.workCommunication), "the goals the set overlaps most, not the saved ones")
        XCTAssertEqual(seeded.enabledFeatureIDs, enabled.subtracting(["not-managed"]))
    }

    // MARK: - What a Continue wrote

    func testWroteChangesFollowsRealWrites() async {
        let model = makeModel()
        model.seedForRerun(enabledFeatureIDs: [], language: "Polish")
        await model.prepare(configuredLanguage: nil)
        _ = await model.submit(hasSlackAccount: true)
        XCTAssertFalse(model.wroteChanges, "no language change, no feature change")

        spy.featuresChanged = true
        _ = await model.submit(hasSlackAccount: true)
        XCTAssertTrue(model.wroteChanges)

        model.seedForRerun(enabledFeatureIDs: [], language: "Polish")
        XCTAssertFalse(model.wroteChanges, "a new run starts clean")
        spy.featuresChanged = false
        await model.prepare(configuredLanguage: nil)
        model.language = "German"
        _ = await model.submit(hasSlackAccount: true)
        XCTAssertTrue(model.wroteChanges, "a language write counts")
    }

    /// `workspace init` fills in Go's history default, so the depth is read
    /// before it: a config that had none still gets the old onboarding's 3.
    func testHistoryDepthIsReadBeforeWorkspaceInit() async {
        spy.historyUnset = true
        let spy = self.spy
        let model = OnboardingGoalsModel(
            defaults: defaults,
            systemLanguage: "Russian",
            checkCLI: { .ready(provider: "claude") },
            actions: OnboardingGoalsActions(
                initWorkspace: {
                    spy.calls.append("workspace init")
                    spy.historyUnset = false
                },
                setLanguage: { spy.calls.append("language \($0)") },
                applyFeatures: { _ in (nil, false) },
                historyDepthUnset: { spy.historyUnset },
                setHistoryDepth: { spy.calls.append("history \($0)") }
            )
        )
        await model.prepare(configuredLanguage: nil)
        _ = await model.submit(hasSlackAccount: false)
        XCTAssertEqual(spy.calls, ["workspace init", "history 3", "language Russian"])
    }
}
