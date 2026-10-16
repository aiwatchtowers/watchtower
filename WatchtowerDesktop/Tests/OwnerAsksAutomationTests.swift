import XCTest
import AppKit
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// An automation's ask (spec §13.3, P5 Task 12): the stack names the
/// automation and its run where a session ask names its session; an answer
/// is written like any other and then wakes the daemon's automations loop;
/// its line never goes into a terminal — not typed, not held, not queued.
@MainActor
final class OwnerAsksAutomationTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var defaults: UserDefaults!
    private var folder: URL!
    private var processes: [FakeTerminalSession] = []
    private var center: TerminalCenter!
    private var runner: FakeCLIRunner!

    nonisolated private static let questions =
        #"{"questions":[{"id":"a","question":"Ship?","options":[{"label":"Yes"},{"label":"No"}]}]}"#

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        defaults = try XCTUnwrap(UserDefaults(suiteName: "OwnerAsksAutomationTests-\(UUID().uuidString)"))
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("wt auto asks \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        processes = []
        runner = FakeCLIRunner()
        center = TerminalCenter(
            makeProcess: { [weak self] in
                let process = FakeTerminalSession()
                self?.processes.append(process)
                return process
            },
            signaller: ProcessGroupSignaller(signal: { _, _ in }, isAlive: { _ in false }, sleep: { _ in })
        )
        center.shell = { "/bin/zsh" }
        center.copyToClipboard = { _ in }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    private func makeVM() -> WorkbenchesViewModel {
        let vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: runner), defaults: defaults, terminalCenter: center)
        vm.asks.hasHookState = { _ in true }
        vm.asks.refreshStates = { true }
        vm.asks.holdSleep = { _ in try? await Task.sleep(for: .seconds(3600)) }
        return vm
    }

    private struct Seed {
        let project: Int64
        let session: TerminalSession
        let run: Int64
        /// Filed by the run (`session_id` NULL, as Go files it).
        let automationAsk: Int64
        /// Filed by the agent of `session`.
        let sessionAsk: Int64
    }

    /// A workbench with one shell session, a workbench automation "Release
    /// check" waiting on its ask, and an agent's ask from the session.
    private func seed() async throws -> Seed {
        let acme = folder.path
        return try await pool.write { d in
            let p = try TestDatabase.insertWorkbench(d, folder: acme)
            let s = try TerminalSessionQueries.create(d, .init(projectID: p, kind: .shell, title: "zsh", folderPath: acme))
            let automation = try TestDatabase.insertAutomation(d, slug: "release-check", name: "Release check", workbenchID: p)
            let run = try TestDatabase.insertAutomationRun(d, automationID: automation, status: "waiting", waitingReason: "ask")
            let automationAsk = try TestDatabase.insertOwnerAsk(d, projectID: p, payload: Self.questions, automationRunID: run)
            let sessionAsk = try TestDatabase.insertOwnerAsk(d, projectID: p, sessionID: s.id, payload: Self.questions)
            return Seed(project: p, session: s, run: run, automationAsk: automationAsk, sessionAsk: sessionAsk)
        }
    }

    private func openAsk(_ vm: WorkbenchesViewModel, project: Int64, id: Int64) async throws -> OwnerAsk {
        await vm.asks.load(projectID: project)
        return try XCTUnwrap(vm.asks.openAsks[project]?.first { $0.id == id })
    }

    private func pick(_ vm: WorkbenchesViewModel, _ askID: Int64) {
        vm.asks.drafts.update(askID) { $0.picks["a"] = .init(labels: ["Yes"]) }
    }

    private func status(_ id: Int64) async throws -> String {
        try await pool.read { d in
            try XCTUnwrap(String.fetchOne(d, sql: "SELECT status FROM owner_asks WHERE id = ?", arguments: [id]))
        }
    }

    private var wakes: Int { runner.invocations.filter { $0 == ["automations", "wake"] }.count }
    private var typed: [[UInt8]] { processes.flatMap(\.inputs) }

    func testAutomationAskShowsAutomationLabel() async throws {
        let s = try await seed()
        let vm = makeVM()
        _ = await vm.loadSessions(projectID: s.project)
        let automationAsk = try await openAsk(vm, project: s.project, id: s.automationAsk)
        let sessionAsk = try XCTUnwrap(vm.asks.openAsks[s.project]?.first { $0.id == s.sessionAsk })

        XCTAssertEqual(vm.askSessionTitle(automationAsk), "⚙ Release check · run #\(s.run)",
                       "the automation and its run where a session ask names its session")
        XCTAssertEqual(vm.askSessionTitle(sessionAsk), "zsh", "a session ask still names its session")
    }

    func testAnswerWakesAutomations() async throws {
        let s = try await seed()
        let vm = makeVM()
        let ask = try await openAsk(vm, project: s.project, id: s.automationAsk)
        pick(vm, s.automationAsk)

        let delivery = await vm.asks.answer(ask)

        XCTAssertEqual(delivery, .noSession)
        let stored = try await status(s.automationAsk)
        XCTAssertEqual(stored, "answered", "open → answered, as for any ask")
        XCTAssertEqual(wakes, 1, "the saved answer wakes the automations loop once")

        // A failed write wakes nothing.
        let second = try await pool.write { d in
            try TestDatabase.insertOwnerAsk(d, projectID: s.project, payload: Self.questions, automationRunID: s.run)
        }
        let other = try await openAsk(vm, project: s.project, id: second)
        pick(vm, second)
        try await pool.write { d in
            try d.execute(sql: """
                CREATE TRIGGER fail_ask_answer BEFORE UPDATE ON owner_asks
                BEGIN SELECT RAISE(ABORT, 'disk full'); END
                """)
        }
        let failed = await vm.asks.answer(other)
        XCTAssertNil(failed)
        XCTAssertEqual(wakes, 1, "a failed answer write → no wake")
    }

    func testAWakeFailureLeavesTheAnswerSaved() async throws {
        let s = try await seed()
        runner.shouldThrow = CLIRunnerError.binaryNotFound
        let vm = makeVM()
        let ask = try await openAsk(vm, project: s.project, id: s.automationAsk)
        pick(vm, s.automationAsk)

        let delivery = await vm.asks.answer(ask)

        XCTAssertEqual(delivery, .noSession, "the wake is best effort")
        let stored = try await status(s.automationAsk)
        XCTAssertEqual(stored, "answered")
        XCTAssertNil(vm.asks.answerErrors[s.automationAsk])
        XCTAssertEqual(vm.asks.noticeText(.delivered(.noSession), ask: ask), OwnerAsksViewModel.automationAnswerNote)
    }

    /// Review focus 3: with a live session in the workbench — at a
    /// permission prompt, even — an automation's answer types nothing,
    /// holds nothing, and `deliverHeldAnswers` sends nothing. So does an
    /// automation ask that names the session (Go never files one; the
    /// guard does not rely on that).
    func testAutomationAskIsNeverDeliveredToATerminal() async throws {
        let s = try await seed()
        let bound = try await pool.write { d in
            try TestDatabase.insertOwnerAsk(d, projectID: s.project, sessionID: s.session.id, payload: Self.questions,
                                            automationRunID: s.run)
        }
        center.start(s.session, fresh: true)
        let vm = makeVM()
        var waiting = true
        vm.asks.needsApproval = { _ in waiting }
        vm.selectedWorkbenchID = s.project
        vm.layout.show(.board)

        for id in [s.automationAsk, bound] {
            let ask = try await openAsk(vm, project: s.project, id: id)
            pick(vm, id)
            let delivery = await vm.asks.answer(ask)
            XCTAssertEqual(delivery, .noSession, "ask #\(id) goes to its run, not a terminal")
            let stored = try await status(id)
            XCTAssertEqual(stored, "answered")
        }
        XCTAssertTrue(typed.isEmpty, "no line typed")
        XCTAssertTrue(vm.lineDelivery.heldKeys(sessionID: s.session.id).isEmpty, "no held line")
        XCTAssertNil(center.answerHints[s.session.id])
        XCTAssertFalse(vm.layout(projectID: s.project).visiblePanes.contains(.session(s.session.id)),
                       "the page is not moved to the session")

        waiting = false
        await vm.asks.deliverHeldAnswers()
        XCTAssertTrue(typed.isEmpty, "deliverHeldAnswers has no entry for them")
        XCTAssertEqual(wakes, 2)
    }

    func testSessionAskDeliveryUnchanged() async throws {
        let s = try await seed()
        center.start(s.session, fresh: true)
        let vm = makeVM()
        vm.selectedWorkbenchID = s.project
        vm.layout.show(.board)
        let ask = try await openAsk(vm, project: s.project, id: s.sessionAsk)
        pick(vm, s.sessionAsk)

        let delivery = await vm.asks.answer(ask)

        XCTAssertEqual(delivery, .submitted)
        XCTAssertEqual(typed.count, 2, "one paste, then its Return")
        XCTAssertEqual(typed.last, [0x0D])
        XCTAssertEqual(wakes, 0, "an agent's ask wakes no automation")
        XCTAssertEqual(vm.asks.noticeText(.delivered(.submitted), ask: ask), OwnerAsksViewModel.answerSentNote)
    }

    /// A closed automation ask is not one "Outside the app": it counts and
    /// lists under the automations' line, its row named by its run.
    func testClosedAutomationAskNamesItsRun() async throws {
        let s = try await seed()
        let outside = try await pool.write { d in
            try d.execute(sql: "UPDATE owner_asks SET status = 'answered', answer = '{}' WHERE id = ?",
                          arguments: [s.automationAsk])
            return try TestDatabase.insertOwnerAsk(d, projectID: s.project, status: "answered", answer: "{}")
        }
        let vm = makeVM()
        await vm.asks.load(projectID: s.project)
        XCTAssertEqual(vm.asks.closedCounts[s.project]?[nil], 1, "only the ask filed outside the app")
        XCTAssertEqual(vm.asks.closedAutomationCounts[s.project], 1)

        await vm.asks.loadClosed(projectID: s.project, sessionID: nil)
        XCTAssertEqual(vm.asks.closedLists[.init(projectID: s.project, sessionID: nil)]?.map(\.id), [outside])
        await vm.asks.loadClosed(projectID: s.project, sessionID: nil, automations: true)
        let closed = try XCTUnwrap(vm.asks.closedLists[.init(projectID: s.project, sessionID: nil, automations: true)])
        XCTAssertEqual(closed.map(\.id), [s.automationAsk])
        XCTAssertEqual(vm.asks.automationLabel(closed[0]), "⚙ Release check · run #\(s.run)")
        XCTAssertEqual(vm.askSessionTitle(closed[0]), "⚙ Release check · run #\(s.run)")
    }
}
