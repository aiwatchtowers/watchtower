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

    private func makeModel(systemLanguage: String = "Russian") -> OnboardingGoalsModel {
        let spy = self.spy
        return OnboardingGoalsModel(
            defaults: defaults,
            systemLanguage: systemLanguage,
            checkCLI: { spy.cliResult },
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
                    return spy.featuresFailure
                }
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
}
