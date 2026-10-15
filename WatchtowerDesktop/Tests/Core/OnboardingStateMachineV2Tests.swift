import XCTest
@testable import WatchtowerCore

@MainActor
final class OnboardingStateMachineV2Tests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "OnboardingStateMachineV2Tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private typealias Machine = OnboardingStateMachineV2

    // MARK: - Legacy migration

    func testEveryLegacyStepMapsOnce() {
        let expected: [Int: OnboardingV2Step] = [
            0: .purpose, 1: .purpose, 2: .purpose, 3: .purpose,
            4: .purpose, 5: .purpose, 6: .purpose, 7: .complete
        ]
        for (raw, step) in expected {
            defaults.removePersistentDomain(forName: suiteName)
            defaults.set(raw, forKey: Machine.legacyStepKey)
            XCTAssertEqual(Machine(defaults: defaults).currentStep, step, "legacy \(raw)")
            XCTAssertEqual(defaults.string(forKey: Machine.stepKey), step.rawValue, "legacy \(raw) is persisted under the v2 key")
        }
    }

    func testUnknownLegacyValueStartsAtGoals() {
        for raw in [-1, 8, 42] {
            defaults.removePersistentDomain(forName: suiteName)
            defaults.set(raw, forKey: Machine.legacyStepKey)
            XCTAssertEqual(Machine(defaults: defaults).currentStep, .purpose, "legacy \(raw)")
        }
    }

    func testFreshInstallStartsAtGoals() {
        XCTAssertEqual(Machine(defaults: defaults).currentStep, .purpose)
    }

    func testMigrationDropsTheLegacyKeysAndRunsOnce() {
        defaults.set(7, forKey: Machine.legacyStepKey)
        defaults.set(true, forKey: "onboarding_sync_completed")
        defaults.set(true, forKey: "onboarding_chat_finished")
        _ = Machine(defaults: defaults)

        XCTAssertNil(defaults.object(forKey: Machine.legacyStepKey))
        XCTAssertNil(defaults.object(forKey: "onboarding_sync_completed"))
        XCTAssertNil(defaults.object(forKey: "onboarding_chat_finished"))

        // A legacy value written later (an old build run again) is ignored:
        // the v2 key wins.
        defaults.set(3, forKey: Machine.legacyStepKey)
        XCTAssertEqual(Machine(defaults: defaults).currentStep, .complete)
    }

    func testUnknownV2ValueStartsAtGoals() {
        defaults.set("teamForm", forKey: Machine.stepKey)
        XCTAssertEqual(Machine(defaults: defaults).currentStep, .purpose)
    }

    /// About you was removed (#758): someone parked on it on upgrade resumes
    /// at Connect, whose Continue finishes — not back at Goals.
    func testRemovedAboutYouStepResumesAtConnect() {
        defaults.set("aboutYou", forKey: Machine.stepKey)
        let machine = Machine(defaults: defaults)
        XCTAssertEqual(machine.currentStep, .connect)
        XCTAssertEqual(OnboardingRoute(goals: [.workCommunication]).step(after: machine.currentStep), .complete)
    }

    // MARK: - Skips

    func testFullRouteRunsEveryStep() {
        let route = OnboardingRoute(goals: [.workCommunication])
        let machine = Machine(defaults: defaults)
        machine.advance(route: route)
        XCTAssertEqual(machine.currentStep, .connect)
        machine.advance(route: route)
        XCTAssertEqual(machine.currentStep, .complete, "Connect is the last step")
        machine.advance(route: route)
        XCTAssertEqual(machine.currentStep, .complete, "advancing past the end stays complete")
    }

    func testOnlyDevelopmentSkipsConnect() {
        let devOnly = OnboardingRoute(goals: [.development])
        XCTAssertTrue(devOnly.skips(.connect))
        XCTAssertEqual(devOnly.step(after: .purpose), .complete)
        XCTAssertTrue(OnboardingRoute(goals: []).skips(.connect), "nothing picked needs no source either")
        XCTAssertFalse(OnboardingRoute(goals: [.development, .meetings]).skips(.connect))
        XCTAssertEqual(OnboardingRoute(goals: [.tasksAndJira]).step(after: .purpose), .connect)
    }

    func testIndicatorHidesEverySkippedStep() {
        XCTAssertEqual(OnboardingRoute(goals: [.meetings]).indicatorSteps, [.purpose, .connect])
        XCTAssertEqual(OnboardingRoute(goals: [.development]).indicatorSteps, [.purpose])
        XCTAssertEqual(OnboardingV2Step.allCases.compactMap(\.indicatorTitle), ["Goals", "Connect"])
    }

    // MARK: - Settle on resume

    func testSettleMovesOffAResumedStepTheRouteSkips() {
        let machine = Machine(defaults: defaults)
        machine.goTo(.connect)
        machine.settle(route: OnboardingRoute(goals: [.development]))
        XCTAssertEqual(machine.currentStep, .complete)
        XCTAssertEqual(Machine(defaults: defaults).currentStep, .complete, "the settled step is persisted")
    }

    func testSettleKeepsAStepTheRouteRuns() {
        let machine = Machine(defaults: defaults)
        machine.goTo(.connect)
        machine.settle(route: OnboardingRoute(goals: [.meetings]))
        XCTAssertEqual(machine.currentStep, .connect)
        machine.goTo(.purpose)
        machine.settle(route: OnboardingRoute(goals: []))
        XCTAssertEqual(machine.currentStep, .purpose, "Goals never skips")
    }

    // MARK: - Run setup again

    func testResetReturnsToGoalsByDefaultAndPersists() {
        let machine = Machine(defaults: defaults)
        machine.goTo(.complete)
        machine.reset()
        XCTAssertEqual(machine.currentStep, .purpose)
        XCTAssertEqual(Machine(defaults: defaults).currentStep, .purpose)

        machine.reset(to: .connect)
        XCTAssertEqual(Machine(defaults: defaults).currentStep, .connect)
    }
}
