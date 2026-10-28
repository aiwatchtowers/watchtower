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

    private func dispatcher(startSessions: Bool = true) -> MobileHubCommandDispatcher {
        let dispatcher = MobileHubCommandDispatcher()
        AutomationRunHandler(
            dbPool: dbPool, quickRun: { [center] in center },
            deviceGrant: { _ in .init(typingAllowed: startSessions, startSessionsAllowed: startSessions) },
            publishSoon: { [weak self] in self?.published.append($0) }
        ).register(on: dispatcher)
        return dispatcher
    }

    private func action(_ automationID: Int64, workbench: Int64) -> ActionRequestPayload {
        ActionRequestPayload(
            id: UUID().uuidString, kind: .automationRun, entityID: String(automationID),
            params: ["workbench_id": .integer(workbench)], createdAt: Date()
        )
    }

    private func seed(confirmedHash: String = "h1", enabled: Bool = true, button confirm: Bool = false)
        async throws -> (workbench: Int64, automation: Int64) {
        try await dbPool.write { db in
            let folder = "/tmp/acme-\(UUID().uuidString)"
            let workbench = try TestDatabase.insertWorkbench(db, name: "acme", folder: folder)
            let automation = try TestDatabase.insertAutomation(
                db, slug: "release", name: "Release", triggerKind: confirm ? "button" : "manual",
                triggerSpec: confirm ? #"{"button":{"label":"Release","confirm":true}}"# : #"{"manual":true}"#,
                confirmedHash: confirmedHash, enabled: enabled, workbenchID: workbench
            )
            return (workbench, automation)
        }
    }

    func testARunnableRecipeRunsThroughQuickRun() async throws {
        let (workbench, automation) = try await seed(button: true)

        let outcome = try await dispatcher().dispatch(action(automation, workbench: workbench))

        XCTAssertEqual(outcome, .applied(["run_id": .integer(1), "coalesced": .bool(false)]))
        XCTAssertEqual(runner.invocations, [["automations", "run", String(automation), "--json"]],
                       "a confirm: true recipe was asked on the phone: no sheet on the Mac")
        XCTAssertNil(center.pendingConfirm)
        XCTAssertEqual(center.watched[1]?.origin, .phone)
        XCTAssertEqual(published, [[.workbench]])
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
        let dispatcher = dispatcher()

        let first = try await dispatcher.dispatch(action(unconfirmed.automation, workbench: unconfirmed.workbench))
        let second = try await dispatcher.dispatch(action(off.automation, workbench: off.workbench))

        XCTAssertEqual(first?.reason, .conflict)
        XCTAssertEqual(first?.errorMessage, "Confirm this automation on the Mac first")
        XCTAssertEqual(second?.errorMessage, "This automation is turned off on the Mac")
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
        XCTAssertEqual(published, [], "nothing changed to publish")
    }

    func testARunIsNeverReplayed() {
        XCTAssertTrue(RelayProcessor.nonIdempotentKinds.contains(.automationRun))
    }
}
