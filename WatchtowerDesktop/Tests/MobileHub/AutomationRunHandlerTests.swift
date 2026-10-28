import Foundation
import GRDB
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerSync
import WatchtowerTestSupport

@MainActor
private final class SilentNotifier: AutomationRunNotifying {
    func runFinished(name: String, status: AutomationRunStatus, summary: String, error: String, automationID: Int64, runID: Int64) {}
    func automationDisabled(name: String, reason: String, automationID: Int64, runID: Int64?) {}
    func automationsFailed(count: Int) {}
    func automationsDisabled(count: Int) {}
}

/// `automation_run` from the phone (ask #692): the start-sessions grant, a
/// recipe of this workbench that can run, quick run's CLI call.
@MainActor
final class AutomationRunHandlerTests: XCTestCase {
    private var dbPool: DatabasePool!
    private var dbPath: String!
    private var runner: FakeCLIRunner!
    private var center: QuickRunCenter!
    private var published: [Set<SliceKind>] = []

    override func setUp() async throws {
        try await super.setUp()
        (dbPool, dbPath) = try TestDatabase.createPool()
        runner = FakeCLIRunner(stdout: Data(#"{"run_id":1,"coalesced":false,"daemon_running":true}"#.utf8))
        let cli = AutomationsCLI(runner: runner)
        let vm = AutomationsViewModel(dbPool: dbPool, cli: cli) { _ in }
        center = QuickRunCenter(dbPool: dbPool, viewModel: vm, cli: cli, notifier: SilentNotifier())
        published = []
    }

    override func tearDown() async throws {
        center = nil
        dbPool = nil
        TestDatabase.cleanup(path: dbPath)
        try await super.tearDown()
    }

    private func dispatcher(startSessions: Bool = true, loaded: Bool = true) -> MobileHubCommandDispatcher {
        let dispatcher = MobileHubCommandDispatcher()
        AutomationRunHandler(
            dbPool: dbPool, quickRun: { [center] in loaded ? center : nil },
            deviceGrant: { _ in .init(typingAllowed: startSessions, startSessionsAllowed: startSessions) },
            publishSoon: { [weak self] in self?.published.append($0) }
        ).register(on: dispatcher)
        return dispatcher
    }

    private func action(_ automationID: Int64, workbench: Int64, confirmed: Bool = false) -> ActionRequestPayload {
        ActionRequestPayload(
            id: UUID().uuidString, kind: .automationRun, entityID: String(automationID),
            params: ["workbench_id": .integer(workbench), "confirmed": .bool(confirmed)], createdAt: Date()
        )
    }

    private func seed(
        confirmedHash: String = "h1", enabled: Bool = true, parseError: String = "", button confirm: Bool = false
    )
        async throws -> (workbench: Int64, automation: Int64) {
        try await dbPool.write { db in
            let folder = "/tmp/acme-\(UUID().uuidString)"
            let workbench = try TestDatabase.insertWorkbench(db, name: "acme", folder: folder)
            let automation = try TestDatabase.insertAutomation(
                db, slug: "release", name: "Release", triggerKind: confirm ? "button" : "manual",
                triggerSpec: confirm ? #"{"button":{"label":"Release","confirm":true}}"# : #"{"manual":true}"#,
                confirmedHash: confirmedHash, parseError: parseError, enabled: enabled, workbenchID: workbench
            )
            return (workbench, automation)
        }
    }

    func testARunnableRecipeRunsThroughQuickRun() async throws {
        let (workbench, automation) = try await seed()

        let outcome = try await dispatcher().dispatch(action(automation, workbench: workbench))

        XCTAssertEqual(outcome, .applied(["run_id": .integer(1), "coalesced": .bool(false)]))
        XCTAssertEqual(runner.invocations, [["automations", "run", String(automation), "--json"]])
        XCTAssertEqual(center.watched[1]?.origin, .phone)
        XCTAssertEqual(published, [[.workbench]])
    }

    /// AUTO-06 (amended, ask #692): a `confirm: true` recipe runs only after
    /// Run in the phone's confirmation, carried as `confirmed`.
    func testAConfirmRecipeRunsOnlyWhenThePhoneConfirmedIt() async throws {
        let (workbench, automation) = try await seed(button: true)
        let dispatcher = dispatcher()

        let unconfirmed = try await dispatcher.dispatch(action(automation, workbench: workbench))
        XCTAssertEqual(unconfirmed?.reason, .conflict)
        XCTAssertEqual(unconfirmed?.errorMessage, "This automation asks before it runs — confirm it on the phone")
        XCTAssertEqual(runner.invocations, [], "nothing runs without the phone's confirmation")

        let outcome = try await dispatcher.dispatch(action(automation, workbench: workbench, confirmed: true))

        XCTAssertEqual(outcome, .applied(["run_id": .integer(1), "coalesced": .bool(false)]))
        XCTAssertEqual(runner.invocations, [["automations", "run", String(automation), "--json"]])
        XCTAssertNil(center.pendingConfirm, "confirmed on the phone: no sheet on the Mac")
    }

    func testAPhoneWithoutTheStartGrantIsRefused() async throws {
        let (workbench, automation) = try await seed()

        let outcome = try await dispatcher(startSessions: false).dispatch(action(automation, workbench: workbench))

        XCTAssertEqual(outcome?.reason, .deviceNotAllowed)
        XCTAssertEqual(runner.invocations, [])
    }

    func testARecipeOfAnotherWorkbenchOrAPersonalOneIsRefused() async throws {
        let (workbench, automation) = try await seed()
        let (other, personal) = try await dbPool.write { db in
            (try TestDatabase.insertWorkbench(db, name: "other", folder: "/tmp/other"),
             try TestDatabase.insertAutomation(db, slug: "mine", name: "Mine"))
        }
        let dispatcher = dispatcher()

        let wrongBoard = try await dispatcher.dispatch(action(automation, workbench: other))
        let mine = try await dispatcher.dispatch(action(personal, workbench: workbench))
        let gone = try await dispatcher.dispatch(action(999, workbench: workbench))

        XCTAssertEqual(wrongBoard?.reason, .notOnBoard)
        XCTAssertEqual(mine?.reason, .notOnBoard)
        XCTAssertEqual(gone?.reason, .notFound)
        XCTAssertEqual(runner.invocations, [])
    }

    func testARecipeThatCannotRunIsRefusedWithItsReason() async throws {
        let unconfirmed = try await seed(confirmedHash: "")
        let off = try await seed(enabled: false)
        let broken = try await seed(parseError: "bad frontmatter")
        let dispatcher = dispatcher()

        let first = try await dispatcher.dispatch(action(unconfirmed.automation, workbench: unconfirmed.workbench))
        let second = try await dispatcher.dispatch(action(off.automation, workbench: off.workbench))
        let third = try await dispatcher.dispatch(action(broken.automation, workbench: broken.workbench))

        XCTAssertEqual(first?.reason, .conflict)
        XCTAssertEqual(first?.errorMessage, "Confirm this automation on the Mac first")
        XCTAssertEqual(second?.errorMessage, "This automation is turned off on the Mac")
        XCTAssertEqual(third?.errorMessage, "This automation can't be read on the Mac")
        XCTAssertEqual(runner.invocations, [], "nothing runs")
    }

    func testARunningRecipeAnswersWithItsRun() async throws {
        let (workbench, automation) = try await seed()
        let runID = try await dbPool.write { db in
            try TestDatabase.insertAutomationRun(db, automationID: automation, status: "running")
        }

        let outcome = try await dispatcher().dispatch(action(automation, workbench: workbench))

        XCTAssertEqual(outcome, .applied(["run_id": .integer(runID), "coalesced": .bool(true)]))
        XCTAssertEqual(runner.invocations, [], "a second run is not started")
    }

    func testARefusedRunIsFailedWithTheCLIMessage() async throws {
        let (workbench, automation) = try await seed()
        runner.shouldThrow = CLIRunnerError.nonZeroExit(code: 1, stderr: "the daemon is not running")

        let outcome = try await dispatcher().dispatch(action(automation, workbench: workbench))

        XCTAssertEqual(outcome?.status, .failed)
        XCTAssertEqual(outcome?.reason, .writeFailed)
        XCTAssertEqual(outcome?.errorMessage?.contains("the daemon is not running"), true, "the CLI's own words reach the phone")
        XCTAssertNil(center.lastError, "the Mac's palette never shows a phone refusal")
        XCTAssertEqual(published, [], "nothing changed to publish")
    }

    func testMissingParamsAndAnUnloadedHubAreRefused() async throws {
        let (workbench, automation) = try await seed()
        let noWorkbench = ActionRequestPayload(
            id: UUID().uuidString, kind: .automationRun, entityID: String(automation), params: [:], createdAt: Date()
        )

        let invalid = try await dispatcher().dispatch(noWorkbench)
        let loading = try await dispatcher(loaded: false).dispatch(action(automation, workbench: workbench))

        XCTAssertEqual(invalid?.reason, .invalidParams)
        XCTAssertEqual(loading?.reason, .writeFailed)
        XCTAssertEqual(loading?.errorMessage, "Automations are loading on the Mac")
        XCTAssertEqual(runner.invocations, [])
    }

    func testARunIsNeverReplayed() {
        XCTAssertTrue(RelayProcessor.nonIdempotentKinds.contains(.automationRun))
    }
}
