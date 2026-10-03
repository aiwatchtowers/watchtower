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

    // MARK: - Skips

    func testFullRouteRunsEveryStep() {
        let route = OnboardingRoute(goals: [.workCommunication], hasSlackAccount: true)
        let machine = Machine(defaults: defaults)
        machine.advance(route: route)
        XCTAssertEqual(machine.currentStep, .connect)
        machine.advance(route: route)
        XCTAssertEqual(machine.currentStep, .aboutYou)
        machine.advance(route: route)
        XCTAssertEqual(machine.currentStep, .complete)
        machine.advance(route: route)
        XCTAssertEqual(machine.currentStep, .complete, "advancing past the end stays complete")
    }

    func testOnlyDevelopmentSkipsConnect() {
        let devOnly = OnboardingRoute(goals: [.development], hasSlackAccount: false)
        XCTAssertTrue(devOnly.skips(.connect))
        XCTAssertEqual(devOnly.step(after: .purpose), .complete)
        XCTAssertTrue(OnboardingRoute(goals: [], hasSlackAccount: false).skips(.connect), "nothing picked needs no source either")
        XCTAssertFalse(OnboardingRoute(goals: [.development, .meetings], hasSlackAccount: false).skips(.connect))
    }

    func testNoSlackAccountSkipsAboutYou() {
        let noSlack = OnboardingRoute(goals: [.tasksAndJira], hasSlackAccount: false)
        XCTAssertEqual(noSlack.step(after: .purpose), .connect)
        XCTAssertEqual(noSlack.step(after: .connect), .complete)
        // A Slack account connected already (e.g. "Run setup again") keeps
        // About you even when Connect is skipped.
        XCTAssertEqual(OnboardingRoute(goals: [.development], hasSlackAccount: true).step(after: .purpose), .aboutYou)
    }

    func testIndicatorHidesEverySkippedStep() {
        XCTAssertEqual(OnboardingRoute(goals: [.meetings], hasSlackAccount: true).indicatorSteps, [.purpose, .connect, .aboutYou])
        XCTAssertEqual(OnboardingRoute(goals: [.meetings], hasSlackAccount: false).indicatorSteps, [.purpose, .connect])
        XCTAssertEqual(OnboardingRoute(goals: [.development], hasSlackAccount: false).indicatorSteps, [.purpose])
        XCTAssertEqual(OnboardingRoute(goals: [.development], hasSlackAccount: true).indicatorSteps, [.purpose, .aboutYou])
        XCTAssertEqual(OnboardingV2Step.allCases.compactMap(\.indicatorTitle), ["Goals", "Connect", "About you"])
    }

    // MARK: - Settle on resume

    func testSettleMovesOffAResumedStepTheRouteSkips() {
        let machine = Machine(defaults: defaults)
        machine.goTo(.connect)
        machine.settle(route: OnboardingRoute(goals: [.development], hasSlackAccount: true))
        XCTAssertEqual(machine.currentStep, .aboutYou)

        machine.goTo(.aboutYou)
        machine.settle(route: OnboardingRoute(goals: [.meetings], hasSlackAccount: false))
        XCTAssertEqual(machine.currentStep, .complete)
        XCTAssertEqual(Machine(defaults: defaults).currentStep, .complete, "the settled step is persisted")
    }

    func testSettleKeepsAStepTheRouteRuns() {
        let machine = Machine(defaults: defaults)
        machine.goTo(.connect)
        machine.settle(route: OnboardingRoute(goals: [.meetings], hasSlackAccount: false))
        XCTAssertEqual(machine.currentStep, .connect)
        machine.goTo(.purpose)
        machine.settle(route: OnboardingRoute(goals: [], hasSlackAccount: false))
        XCTAssertEqual(machine.currentStep, .purpose, "Goals never skips")
    }

    // MARK: - Run setup again

    func testResetReturnsToGoalsByDefaultAndPersists() {
        let machine = Machine(defaults: defaults)
        machine.goTo(.complete)
        machine.reset()
        XCTAssertEqual(machine.currentStep, .purpose)
        XCTAssertEqual(Machine(defaults: defaults).currentStep, .purpose)

        machine.reset(to: .aboutYou)
        XCTAssertEqual(Machine(defaults: defaults).currentStep, .aboutYou)
    }
}
