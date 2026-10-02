import XCTest
@testable import WatchtowerCore

/// Onboarding goals → feature set, and the Customize screen's
/// manual-override/reset rule over it.
final class OnboardingFeaturePlanTests: XCTestCase {
    private typealias Plan = OnboardingFeaturePlan

    private let workCommunication: Set<String> = [
        "secretary-inbox", "slack-digests", "tracks", "people-cards",
        "briefing", "day-plan", "ideas", "reaction-commands"
    ]

    // MARK: - Mapping

    func testWorkCommunication() {
        XCTAssertEqual(Plan.enabledFeatureIDs(for: [.workCommunication]),
                       workCommunication.union(["knowledge-search"]))
    }

    func testWorkCommunicationAlwaysCarriesSlackDigests() {
        // Tracks and People Cards mine the digests and starve without them.
        XCTAssertTrue(Plan.featureIDs(for: .workCommunication).contains("slack-digests"))
    }

    func testTasksAndJira() {
        XCTAssertEqual(Plan.enabledFeatureIDs(for: [.tasksAndJira]),
                       ["stream-digests", "next-step", "knowledge-search"])
    }

    func testMeetings() {
        XCTAssertEqual(Plan.enabledFeatureIDs(for: [.meetings]), ["briefing", "knowledge-search"])
    }

    func testOnlyDevelopmentEnablesOnlyTheAlwaysOnSet() {
        XCTAssertEqual(Plan.enabledFeatureIDs(for: [.development]), ["knowledge-search"])
    }

    func testNoGoalsIsTheSameAsOnlyDevelopment() {
        XCTAssertEqual(Plan.enabledFeatureIDs(for: []), Plan.enabledFeatureIDs(for: [.development]))
    }

    func testGoalsUnion() {
        XCTAssertEqual(Plan.enabledFeatureIDs(for: [.workCommunication, .tasksAndJira, .meetings]),
                       workCommunication.union(["stream-digests", "next-step", "knowledge-search"]))
    }

    func testMemoryIsOffForEveryGoalCombination() {
        XCTAssertFalse(Plan.enabledFeatureIDs(for: Set(OnboardingGoal.allCases)).contains("memory"))
        XCTAssertTrue(Plan.managedFeatureIDs.contains("memory"), "off means written off, not left alone")
    }

    func testManagedSetExcludesCoreAndConfluence() {
        // Core entries have no switch (the CLI rejects enable/disable on
        // them); Confluence in search is a Settings affordance, left as is.
        for id in ["targets", "chat", "knowledge-connectors"] {
            XCTAssertFalse(Plan.managedFeatureIDs.contains(id), id)
        }
    }

    func testCustomizableSetIsManagedMinusAlwaysOn() {
        XCTAssertEqual(Plan.customizableFeatureIDs, Plan.managedFeatureIDs.subtracting(["knowledge-search"]))
        XCTAssertTrue(Plan.customizableFeatureIDs.contains("memory"))
    }

    // MARK: - Selection: goals decide until a manual flip

    func testFreshSelectionFollowsGoals() {
        var selection = OnboardingFeatureSelection(goals: [.meetings])
        XCTAssertFalse(selection.isCustomized)
        selection.goals.insert(.tasksAndJira)
        XCTAssertEqual(selection.enabledFeatureIDs, Plan.enabledFeatureIDs(for: [.meetings, .tasksAndJira]))
    }

    func testManualOverrideWinsOverLaterGoalChanges() {
        var selection = OnboardingFeatureSelection(goals: [.workCommunication])
        selection.setFeature("tracks", enabled: false)
        selection.setFeature("memory", enabled: true)
        let picked = workCommunication.subtracting(["tracks"]).union(["memory", "knowledge-search"])
        XCTAssertTrue(selection.isCustomized)
        XCTAssertEqual(selection.enabledFeatureIDs, picked)

        selection.goals = [.tasksAndJira]
        XCTAssertEqual(selection.enabledFeatureIDs, picked, "goals no longer move features once customized")
        selection.goals = []
        XCTAssertEqual(selection.enabledFeatureIDs, picked)
    }

    func testFlipBackToTheMappedValueStaysCustomized() {
        var selection = OnboardingFeatureSelection(goals: [.meetings])
        selection.setFeature("briefing", enabled: false)
        selection.setFeature("briefing", enabled: true)
        XCTAssertTrue(selection.isCustomized)
        selection.goals.insert(.tasksAndJira)
        XCTAssertFalse(selection.isEnabled("next-step"))
    }

    func testResetReturnsToTheMapping() {
        var selection = OnboardingFeatureSelection(goals: [.workCommunication])
        selection.setFeature("ideas", enabled: false)
        selection.goals = [.tasksAndJira]
        selection.resetToGoals()
        XCTAssertFalse(selection.isCustomized)
        XCTAssertEqual(selection.enabledFeatureIDs, Plan.enabledFeatureIDs(for: [.tasksAndJira]))
        selection.goals.insert(.meetings)
        XCTAssertTrue(selection.isEnabled("briefing"), "goals decide again after a reset")
    }

    func testResetOnAnUncustomizedSelectionIsANoOp() {
        var selection = OnboardingFeatureSelection(goals: [.meetings])
        selection.resetToGoals()
        XCTAssertEqual(selection, OnboardingFeatureSelection(goals: [.meetings]))
    }

    func testUnmanagedOrAlwaysOnIDsAreIgnored() {
        var selection = OnboardingFeatureSelection(goals: [.development])
        selection.setFeature("knowledge-connectors", enabled: true)
        selection.setFeature("knowledge-search", enabled: false)
        selection.setFeature("targets", enabled: false)
        XCTAssertFalse(selection.isCustomized)
        XCTAssertEqual(selection.enabledFeatureIDs, ["knowledge-search"])
    }
}
