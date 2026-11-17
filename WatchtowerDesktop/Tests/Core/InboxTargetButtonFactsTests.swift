import XCTest
import GRDB
@testable import WatchtowerCore
import WatchtowerInterface
import WatchtowerTestSupport

/// The Inbox center's target button facts (Inbox builder A, plan Task 15):
/// the newest proposal per button context, whether its task exists, the
/// press error it keeps across navigation, and Try again on the same row.
@MainActor
final class InboxTargetButtonFactsTests: XCTestCase {
    private let context = "OUT:0:0123456789abcdef"

    private struct Fixture {
        let pool: DatabasePool
        let path: String
        let outputID: Int64
        let context: String
        let tower: FeedCaseTransport
    }

    /// Go's case `name` (default: automation 1's artifact 1 with one target
    /// button, listed), seeded into a fresh pool.
    private func fixture(_ name: String = "desktop_target_button_output") async throws -> Fixture {
        let (pool, path) = try TestDatabase.createPool()
        let tower = try FeedCaseTransport.seeded(name, pool: pool)
        let outputID: Int64 = 1
        return Fixture(pool: pool, path: path, outputID: outputID,
                       context: context.replacingOccurrences(of: "OUT", with: String(outputID)), tower: tower)
    }

    /// Lists the case through its tower the first time, then reads again.
    private func list(_ vm: ActionStripViewModel, _ fx: Fixture) async {
        if vm.feedLoader == nil { await vm.follow(fx.tower) } else { await vm.refresh() }
    }

    @discardableResult
    private func proposal(
        _ fx: Fixture,
        status: String,
        context: String? = nil,
        decidedAt: String = "2026-09-04T10:00:00Z",
        result: String = ""
    ) async throws -> Int64 {
        try await fx.pool.write { db in
            try TestDatabase.insertAgentAction(
                db, surface: "inbox", contextType: "automation_output", contextID: context ?? fx.context,
                status: status, resultJSON: result, decidedAt: decidedAt)
        }
    }

    private func press(_ fx: Fixture) -> InboxTargetPress {
        let card = AutomationOutputCard(id: fx.outputID, automationID: 1, automationName: "Acme digest", runID: 1,
                                        title: "Weekly", body: "", priority: "medium",
                                        createdAt: Date(timeIntervalSince1970: 0))
        return InboxTargetPress(card: card, index: 0,
                                target: InboxCardAction.Target(title: "Sign off", intent: nil, parent: nil,
                                                               hash: "0123456789abcdef"))
    }

    // MARK: - The queries

    func testNewestRowPerContextAndItsTask() async throws {
        let fx = try await fixture()
        defer { TestDatabase.cleanup(path: fx.path) }
        try await proposal(fx, status: "rejected")
        let newest = try await proposal(fx, status: "applied", result: #"{"target_id":1}"#)
        let other = try await proposal(fx, status: "pending", context: "\(fx.outputID):1:ffff")
        // Another output's button and a row of another context type are left out.
        try await proposal(fx, status: "pending", context: "999:0:aaaa")
        try await fx.pool.write { db in
            _ = try TestDatabase.insertAgentAction(db, contextType: "automation_run", contextID: "\(fx.outputID)")
        }

        let rows = try await fx.pool.read { db in
            try AgentActionQueries.newestButtonProposals(db, outputIDs: [fx.outputID], contextIDs: [])
        }
        XCTAssertEqual(rows.mapValues(\.id), [fx.context: newest, "\(fx.outputID):1:ffff": other])
        let byContext = try await fx.pool.read { db in
            try AgentActionQueries.newestButtonProposals(db, outputIDs: [], contextIDs: ["999:0:aaaa"])
        }
        XCTAssertEqual(Array(byContext.keys), ["999:0:aaaa"])
        let none = try await fx.pool.read { db in
            try AgentActionQueries.newestButtonProposals(db, outputIDs: [], contextIDs: [])
        }
        XCTAssertTrue(none.isEmpty)

        var tasks = try await fx.pool.read { db in try AgentActionQueries.actionsWithTask(db, actionIDs: [newest]) }
        XCTAssertTrue(tasks.isEmpty)
        let taskID = try await fx.pool.write { db -> Int64 in
            let id = try TestDatabase.insertTarget(db, sourceType: "chat", sourceID: "action:\(newest)")
            // A renamed duplicate is not the row's task.
            _ = try TestDatabase.insertTarget(db, sourceType: "chat", sourceID: "action:\(newest):dup9")
            return id
        }
        tasks = try await fx.pool.read { db in try AgentActionQueries.actionsWithTask(db, actionIDs: [newest, 77]) }
        XCTAssertEqual(tasks, [newest: taskID])
    }

    func testFactsFromTheCenter() async throws {
        let fx = try await fixture()
        defer { TestDatabase.cleanup(path: fx.path) }
        let id = try await proposal(fx, status: "applied", result: #"{"target_id":1}"#)
        try await fx.pool.write { db in
            _ = try TestDatabase.insertTarget(db, sourceType: "chat", sourceID: "action:\(id)")
        }
        let vm = ActionStripViewModel(dbPool: fx.pool, cliRunner: FakeCLIRunner())
        await list(vm, fx)

        let facts = vm.targetButton(contextID: fx.context, action: nil)
        XCTAssertEqual(facts.proposalID, id)
        XCTAssertNotNil(facts.taskID)
                XCTAssertFalse(facts.inFlight)
        XCTAssertNil(facts.pressError)
        // Another index or hash of the same output finds nothing.
        XCTAssertNil(vm.targetButton(contextID: "\(fx.outputID):0:fedcba9876543210", action: nil).proposalID)
    }

    // MARK: - The press

    func testPressProposesWithoutApprove() async throws {
        let fx = try await fixture()
        defer { TestDatabase.cleanup(path: fx.path) }
        let runner = FakeCLIRunner(stdout: Data(#"{"ok":true}"#.utf8))
        let vm = ActionStripViewModel(dbPool: fx.pool, cliRunner: runner)
        await list(vm, fx)

        await vm.proposeTarget(press(fx))

        XCTAssertEqual(runner.invocations, [press(fx).arguments])
        XCTAssertNil(vm.targetButton(contextID: fx.context, action: nil).pressError)
        XCTAssertFalse(vm.proposingTargets.contains(fx.context))
    }

    func testTargetButton_ProposeErrorFromCenter() async throws {
        let fx = try await fixture()
        defer { TestDatabase.cleanup(path: fx.path) }
        let runner = FakeCLIRunner(error: CLIRunnerError.nonZeroExit(code: 1, stderr: "Error: parent_id: task #3 is closed\n"))
        let vm = ActionStripViewModel(dbPool: fx.pool, cliRunner: runner)
        await list(vm, fx)

        // Exit 1: kept for the button, as stderr's own text; no Inbox banner.
        await vm.proposeTarget(press(fx))
        XCTAssertEqual(vm.targetButton(contextID: fx.context, action: nil).pressError, "parent_id: task #3 is closed")
        XCTAssertNil(vm.lastError)

        // Navigating away and back (off screen, another card, a read) keeps it.
        vm.setOnScreen(false)
        await vm.select(.output(fx.outputID))
        await list(vm, fx)
        vm.setOnScreen(true)
        await vm.onScreenRefresh?.value
        XCTAssertEqual(vm.targetButton(contextID: fx.context, action: nil).pressError, "parent_id: task #3 is closed")

        // The next propose that lands clears it.
        runner.shouldThrow = nil
        await vm.proposeTarget(press(fx))
        XCTAssertNil(vm.targetButton(contextID: fx.context, action: nil).pressError)

        // Exit 3 stores nothing.
        runner.shouldThrow = CLIRunnerError.nonZeroExit(code: 3, stderr: "This button already has a proposal (#4)")
        await vm.proposeTarget(press(fx))
        XCTAssertNil(vm.targetButton(contextID: fx.context, action: nil).pressError)

        // A read that finds a row newer than the one seen at the press clears it.
        runner.shouldThrow = CLIRunnerError.nonZeroExit(code: 1, stderr: "busy")
        await vm.proposeTarget(press(fx))
        XCTAssertEqual(vm.targetButton(contextID: fx.context, action: nil).pressError, "busy")
        try await proposal(fx, status: "pending")
        await list(vm, fx)
        XCTAssertNil(vm.targetButton(contextID: fx.context, action: nil).pressError)
    }

    /// A refusal after a warning line shows the refusal alone (the CLI's
    /// last stderr line, as the folder menu reads it).
    func testPressRefusalIsTheLastStderrLine() {
        let error = CLIRunnerError.nonZeroExit(code: 1, stderr: "warning: config key renamed\nError: busy\n")
        XCTAssertEqual(ActionStripViewModel.pressRefusal(error), "busy")
        XCTAssertEqual(ActionStripViewModel.pressRefusal(CLIRunnerError.nonZeroExit(code: 2, stderr: "\n")),
                       "watchtower exited with code 2")
    }

    /// After a rejected proposal the button is pressable; a failed press
    /// keeps its reason while the rejected row is still the newest.
    func testProposeErrorSurvivesTheReadWhenNoNewRow() async throws {
        let fx = try await fixture()
        defer { TestDatabase.cleanup(path: fx.path) }
        try await proposal(fx, status: "rejected")
        let runner = FakeCLIRunner(error: CLIRunnerError.nonZeroExit(code: 1, stderr: "busy"))
        let vm = ActionStripViewModel(dbPool: fx.pool, cliRunner: runner)
        await list(vm, fx)
        await vm.proposeTarget(press(fx))
        await list(vm, fx)
        XCTAssertEqual(vm.targetButton(contextID: fx.context, action: nil).pressError, "busy")
    }

    func testTargetButton_Exit3RereadsWithoutBanner() async throws {
        let fx = try await fixture()
        defer { TestDatabase.cleanup(path: fx.path) }
        let runner = FakeCLIRunner(error: CLIRunnerError.nonZeroExit(code: 3, stderr: "This button already has a proposal (#1)"))
        // Another window's press wrote the row meanwhile.
        let pool = fx.pool
        let context = fx.context
        runner.onRun = { _ in
            _ = try? await pool.write { db in
                try TestDatabase.insertAgentAction(db, surface: "inbox", contextType: "automation_output",
                                                   contextID: context, status: "pending")
            }
        }
        let vm = ActionStripViewModel(dbPool: fx.pool, cliRunner: runner)
        await list(vm, fx)

        await vm.proposeTarget(press(fx))

        let facts = vm.targetButton(contextID: fx.context, action: nil)
        XCTAssertNotNil(facts.proposalID, "the row the other press wrote is read")
        XCTAssertNil(facts.pressError)
        XCTAssertNil(vm.lastError)
    }

    func testSecondPressWhileProposingIsDropped() async throws {
        let fx = try await fixture()
        defer { TestDatabase.cleanup(path: fx.path) }
        let runner = FakeCLIRunner(stdout: Data(#"{"ok":true}"#.utf8))
        runner.blockUntilCancelled = true
        runner.returnDataOnCancelInsteadOfThrowing = true
        let vm = ActionStripViewModel(dbPool: fx.pool, cliRunner: runner)
        await list(vm, fx)

        let first = Task { await vm.proposeTarget(press(fx)) }
        await runner.untilInvocations(1)
        XCTAssertTrue(vm.proposingTargets.contains(fx.context))
        await vm.proposeTarget(press(fx))
        XCTAssertEqual(runner.invocations.count, 1)
        first.cancel()
        await first.value
        XCTAssertFalse(vm.proposingTargets.contains(fx.context))
    }

    // MARK: - Try again

    func testTryAgainAppliesTheSameRow() async throws {
        let fx = try await fixture()
        defer { TestDatabase.cleanup(path: fx.path) }
        let runner = FakeCLIRunner(stdout: Data(#"{"ok":true,"applied_ok":true}"#.utf8))
        let vm = ActionStripViewModel(dbPool: fx.pool, cliRunner: runner)

        for (status, extra) in [("approved", [String]()), ("executing", ["--force"]), ("failed", [])] {
            let id = try await proposal(fx, status: status, context: "\(fx.outputID):0:\(status)")
            await list(vm, fx)
            await vm.tryAgainTarget(id)
            XCTAssertEqual(runner.invocations.last, ["actions", "apply", String(id)] + extra + ["--json"], status)
        }
        XCTAssertFalse(runner.invocations.contains { $0.contains("propose") })
    }

    /// A Try again the CLI refuses with exit 3 (a newer proposal is open):
    /// no error on the row, the read draws the state.
    func testTryAgainExit3IsNoError() async throws {
        let fx = try await fixture()
        defer { TestDatabase.cleanup(path: fx.path) }
        let id = try await proposal(fx, status: "failed")
        let runner = FakeCLIRunner(error: CLIRunnerError.nonZeroExit(code: 3, stderr: "A newer proposal for this button is open (#9)"))
        let vm = ActionStripViewModel(dbPool: fx.pool, cliRunner: runner)
        await list(vm, fx)
        await vm.tryAgainTarget(id)
        XCTAssertNil(vm.actionFeed.rowErrors[id])
        XCTAssertNil(vm.targetButton(contextID: fx.context, action: nil).applyError)
    }

    /// A Try again whose CLI fails without moving the row keeps its reason
    /// for the button; navigating away during it keeps the result.
    func testTryAgainFailureIsKept() async throws {
        let fx = try await fixture()
        defer { TestDatabase.cleanup(path: fx.path) }
        let id = try await proposal(fx, status: "executing")
        let runner = FakeCLIRunner(error: CLIRunnerError.nonZeroExit(code: 1, stderr: "database is locked"))
        let vm = ActionStripViewModel(dbPool: fx.pool, cliRunner: runner)
        await list(vm, fx)
        let running = Task { await vm.tryAgainTarget(id) }
        vm.setOnScreen(false)
        await running.value
        vm.setOnScreen(true)
        await vm.onScreenRefresh?.value
        XCTAssertTrue(vm.targetButton(contextID: fx.context, action: nil).applyError?.contains("database is locked") == true)
    }

    /// Which row is its button's newest is Go's (`Approval.target`,
    /// `Approval.superseded`): an older row is never offered Try again.
    func testOnlyTheNewestRowIsTheButtons() async throws {
        // Artifact 1's button: its failed row 1, then its pending row 2.
        let fx = try await fixture("desktop_target_button_newest_rows")
        defer { TestDatabase.cleanup(path: fx.path) }
        let (older, newer): (Int64, Int64) = (1, 2)
        let vm = ActionStripViewModel(dbPool: fx.pool, cliRunner: FakeCLIRunner())
        await list(vm, fx)
        let rows = try await fx.pool.read { db in
            (try AgentActionQueries.fetch(db, id: older), try AgentActionQueries.fetch(db, id: newer))
        }
        let olderRow = try XCTUnwrap(rows.0)
        let newerRow = try XCTUnwrap(rows.1)
        XCTAssertNil(vm.targetButton(forApproval: olderRow))
        XCTAssertTrue(vm.isSupersededButtonRow(olderRow))
        let button = try XCTUnwrap(vm.targetButton(forApproval: newerRow))
        XCTAssertEqual(button.detail, "waiting")
        XCTAssertEqual(button.proposalID, newer)
        XCTAssertFalse(vm.isSupersededButtonRow(newerRow))
    }

    /// The button's state is the feed's action at its press index.
    func testButtonStateIsTheFeedsAction() async throws {
        // Artifact 1's button (its Go hash) with failed row 1.
        let fx = try await fixture("desktop_target_button_failed")
        defer { TestDatabase.cleanup(path: fx.path) }
        let id: Int64 = 1
        let vm = ActionStripViewModel(dbPool: fx.pool, cliRunner: FakeCLIRunner())
        await list(vm, fx)
        let action = try XCTUnwrap(vm.feedCard("o1")?.actions.first)
        let button = vm.targetButton(contextID: "1:0:78467113208dbfff", action: action)
        XCTAssertEqual(button.detail, "failed")
        XCTAssertEqual(button.note, "parent_id: task #3 is closed")
        XCTAssertEqual(button.proposalID, id, "Try again applies the newest row")
    }

}

/// A pending target proposal whose artifact went away, or whose living
/// rewrite changed the drawn action's hash: its approval card stays in
/// Needs approval and still approves (the same `actions approve`); the
/// button drawn now has another context, so it is idle.
@MainActor
final class InboxTargetOrphanedProposalTests: XCTestCase {
    private let suite = "InboxTargetOrphanedProposalTests.\(UUID().uuidString)"

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func check(deleteOutput: Bool) async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        // Proposal 1 for artifact 1's button 1:0:0123456789abcdef; the
        // artifact gone, or still there with its button drawn under another hash.
        let tower = try FeedCaseTransport.seeded(
            deleteOutput ? "desktop_target_orphan_output_deleted" : "desktop_target_orphan_hash_changed", pool: pool)
        let (outputID, proposalID, approvals): (Int64, Int64, Int64) = (1, 1, 2)
        let runner = FakeCLIRunner(stdout: Data(#"{"ok":true,"applied_ok":true,"error":""}"#.utf8))
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let vm = ActionStripViewModel(dbPool: pool, cliRunner: runner, defaults: defaults)
        await vm.follow(tower)
        vm.selectFolder(approvals)
        XCTAssertTrue(vm.folderEntries.contains { $0.id == "approval:action:\(proposalID)" },
                      "the open approval stays on screen")
        // The button drawn now (another hash, or no card at all) has no proposal.
        let now = vm.targetButton(contextID: "\(outputID):0:fedcba9876543210", action: nil)
        XCTAssertNil(now.proposalID)
        XCTAssertFalse(now.inFlight)

        let action = try XCTUnwrap(vm.feed.proposals.first { $0.id == proposalID })
        await vm.approve(proposalID, shownArgs: action.argsJSON)
        XCTAssertEqual(runner.invocations.first?.prefix(3).map { $0 }, ["actions", "approve", "\(proposalID)"])
    }

    func testArtifactDeletedWhilePending() async throws {
        try await check(deleteOutput: true)
    }

    func testContentHashChangedWhilePending() async throws {
        try await check(deleteOutput: false)
    }
}

/// A waiting button's click opens Needs approval when it shows the card,
/// and otherwise keeps the card on screen with a notice (review A15 #1).
@MainActor
final class InboxTargetOpenProposalTests: XCTestCase {
    func testOpenProposalNotListedKeepsTheSelection() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        // Acme digest's output 1, and proposal 1: a row the strip never lists
        // (the inbox surface's one-press tool, STRIP-01): openProposal finds it
        // nowhere in Go's list.
        let tower = try FeedCaseTransport.seeded("desktop_proposal_not_listed", pool: pool)
        let (outputID, proposalID): (Int64, Int64) = (1, 1)
        let vm = ActionStripViewModel(dbPool: pool, cliRunner: FakeCLIRunner())
        await vm.follow(tower)
        await vm.open(folder: nil, select: .card(.output(outputID)))
        XCTAssertEqual(vm.selection, .output(outputID))

        await vm.openProposal(proposalID)

        XCTAssertEqual(vm.selection, .output(outputID))
        XCTAssertEqual(vm.lastError, ActionStripViewModel.proposalNotListed(proposalID))
    }

    func testOpenProposalListedOpensNeedsApproval() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        // Proposal 1 of a card's button; Needs approval is folder 2.
        let tower = try FeedCaseTransport.seeded("desktop_proposal_listed", pool: pool)
        let (proposalID, approvals): (Int64, Int64) = (1, 2)
        let vm = ActionStripViewModel(dbPool: pool, cliRunner: FakeCLIRunner())
        await vm.follow(tower)
        await vm.open(folder: nil, select: nil)
        await vm.openProposal(proposalID)
        // A proposal is drawn in Needs approval's stack (inbox builder B).
        XCTAssertEqual(vm.folderMenu.selectedFolderID, approvals)
        XCTAssertEqual(vm.entrySelection, "approval:action:\(proposalID)", "its card is selected for the scroll")
        XCTAssertNil(vm.lastError)
    }

    /// A card's target button proposal (create_target on the inbox surface)
    /// is an approval since the STRIP-01 narrowing: its click opens it.
    func testOpenProposalOfAnInboxTargetButtonOpensNeedsApproval() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        // Proposal 1 of an Inbox target button; Needs approval is folder 2.
        let tower = try FeedCaseTransport.seeded("desktop_proposal_inbox_target_button", pool: pool)
        let (proposalID, approvals): (Int64, Int64) = (1, 2)
        let vm = ActionStripViewModel(dbPool: pool, cliRunner: FakeCLIRunner())
        await vm.follow(tower)
        await vm.open(folder: nil, select: nil)
        await vm.openProposal(proposalID)
        // A proposal is drawn in Needs approval's stack (inbox builder B).
        XCTAssertEqual(vm.folderMenu.selectedFolderID, approvals)
        XCTAssertEqual(vm.entrySelection, "approval:action:\(proposalID)", "its card is selected for the scroll")
        XCTAssertNil(vm.lastError)
    }
}
