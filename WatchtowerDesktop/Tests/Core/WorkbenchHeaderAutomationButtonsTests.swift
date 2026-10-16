import XCTest
import GRDB
@testable import WatchtowerCore
import WatchtowerTestSupport

/// Records every CLI call and answers `run`; optionally holds `run` at a
/// gate until the test opens it.
private final class RecordingRunner: CLIRunnerProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    private var onRun: (@Sendable () throws -> Void)?
    private var holds = false
    private var gate: CheckedContinuation<Void, Never>?
    private var gateOpened = false

    var invocations: [[String]] { lock.withLock { recorded } }
    var isHolding: Bool { lock.withLock { gate != nil } }

    func whenRun(_ body: @escaping @Sendable () throws -> Void) { lock.withLock { onRun = body } }
    func holdRun() { lock.withLock { holds = true } }

    func release() {
        let waiting: CheckedContinuation<Void, Never>? = lock.withLock {
            gateOpened = true
            defer { gate = nil }
            return gate
        }
        waiting?.resume()
    }

    func run(args: [String]) async throws -> Data {
        let (body, held) = lock.withLock {
            recorded.append(args)
            return (onRun, holds && args.count > 1 && args[1] == "run")
        }
        if held {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = lock.withLock {
                    if gateOpened { return true }
                    gate = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }
        try body?()
        return Data(#"{"run_id":9,"coalesced":false,"daemon_running":true}"#.utf8)
    }
}

@MainActor
final class WorkbenchHeaderAutomationButtonsTests: XCTestCase {
    private typealias Model = WorkbenchAutomationButtonsModel
    private var pool: DatabasePool!
    private var path = ""
    private var runner: RecordingRunner!

    override func setUp() async throws {
        try await super.setUp()
        (pool, path) = try TestDatabase.createPool()
        runner = RecordingRunner()
    }

    override func tearDown() async throws {
        runner.release()
        pool = nil
        TestDatabase.cleanup(path: path)
        try await super.tearDown()
    }

    private func makeViewModel() -> AutomationsViewModel {
        AutomationsViewModel(dbPool: pool, cli: AutomationsCLI(runner: runner)) { _ in }
    }

    private func button(
        _ slug: String = "deploy",
        label: String = "Deploy",
        confirm: Bool = false,
        state: AutomationHeaderButton.State = .runnable,
        activeRunID: Int64? = nil,
        id: Int64 = 1
    ) -> AutomationHeaderButton {
        AutomationHeaderButton(automationID: id, slug: slug, label: label, confirm: confirm, state: state,
                               activeRunID: activeRunID)
    }

    nonisolated private static func insertButton(_ db: Database, slug: String = "deploy", workbench: Int64) throws -> Int64 {
        try TestDatabase.insertAutomation(db, slug: slug, name: slug.capitalized, triggerKind: "button",
                                          triggerSpec: #"{"button":{"label":"Deploy","confirm":false}}"#,
                                          workbenchID: workbench)
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("timed out")
                return
            }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - Pure model

    func testRunnableStatesAndActions() {
        let cases: [(AutomationHeaderButton, Model.Action, Bool, String?)] = [
            (button(confirm: true), .confirmThenRun(label: "Deploy"), false, nil),
            (button(), .run, false, nil),
            (button(activeRunID: 42), .openRun(42), false, "Running — show the run"),
            (button(state: .needsConfirmation), .openConfirmSheet, true, "Needs your confirmation"),
            (button(state: .disabled), .openCard, true, "Disabled"),
            (button(state: .parseError), .openCard, true, "Parse error")
        ]
        for (b, action, dimmed, help) in cases {
            XCTAssertEqual(Model.action(for: b), action, "\(b.state)")
            XCTAssertEqual(Model.isDimmed(b), dimmed, "\(b.state)")
            XCTAssertEqual(Model.help(for: b), help, "\(b.state)")
        }
    }

    /// An active run wins the help text as it wins the click, in any state:
    /// the help says what the click does.
    func testActiveRunHelpWinsOverState() {
        for state in [AutomationHeaderButton.State.runnable, .needsConfirmation, .disabled, .parseError] {
            let b = button(state: state, activeRunID: 7)
            XCTAssertEqual(Model.action(for: b), .openRun(7), "\(state)")
            XCTAssertEqual(Model.help(for: b), "Running — show the run", "\(state)")
        }
    }

    func testConfirmTrueAsksFirst() async throws {
        let b = button(confirm: true)
        XCTAssertEqual(Model.action(for: b), .confirmThenRun(label: "Deploy"))
        XCTAssertEqual(Model.confirmTitle(label: "Deploy"), "Run Deploy?")
        // The click itself runs nothing; only the dialog's **Run** does.
        let vm = makeViewModel()
        var opened: [(Int64, Int64?)] = []
        await Model.perform(Model.action(for: b), on: b, vm: vm) { opened.append(($0, $1)) }
        XCTAssertEqual(runner.invocations, [])
        XCTAssertTrue(opened.isEmpty)
        await Model.perform(.run, on: b, vm: vm) { opened.append(($0, $1)) }
        XCTAssertEqual(runner.invocations, [["automations", "run", "1", "--json"]])
    }

    func testMaxFourVisibleRestInOverflowSlugOrder() {
        let slugs = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot"]
        let buttons = slugs.enumerated().map { button($1, label: $1, id: Int64($0 + 1)) }
        let (visible, overflow) = Model.layout(buttons)
        XCTAssertEqual(visible.map(\.slug), ["alpha", "bravo", "charlie", "delta"])
        XCTAssertEqual(overflow.map(\.slug), ["echo", "foxtrot"])
        let few = Model.layout(Array(buttons.prefix(3)))
        XCTAssertEqual(few.visible.count, 3)
        XCTAssertTrue(few.overflow.isEmpty)
    }

    func testActiveRunShowsSpinnerAndOpensRun() async {
        let b = button(activeRunID: 42)
        XCTAssertTrue(Model.isSpinning(b, busy: false))
        XCTAssertTrue(Model.isSpinning(button(), busy: true), "the run call in flight spins too")
        XCTAssertFalse(Model.isSpinning(button(), busy: false))
        let vm = makeViewModel()
        var opened: [(Int64, Int64?)] = []
        await Model.perform(Model.action(for: b), on: b, vm: vm) { opened.append(($0, $1)) }
        XCTAssertEqual(opened.map(\.0), [1])
        XCTAssertEqual(opened.map(\.1), [42])
        XCTAssertEqual(runner.invocations, [], "an active run opens; it never starts another")
    }

    func testNeedsConfirmationOpensTheConfirmSheet() async {
        let b = button(state: .needsConfirmation)
        let vm = makeViewModel()
        var opened: [(Int64, Int64?)] = []
        await Model.perform(Model.action(for: b), on: b, vm: vm) { opened.append(($0, $1)) }
        XCTAssertEqual(vm.pendingConfirmID, 1)
        XCTAssertEqual(opened.map(\.0), [1])
        XCTAssertEqual(runner.invocations, [])
    }

    /// AUTO-09 (Desktop): a header button only queues. A click on a runnable
    /// button is exactly one `automations run <id> --json`; Swift runs no
    /// generator or shell and writes no row itself.
    func testAuto09_HeaderButtonOnlyQueues() async throws {
        let (p, id) = try await pool.write { db -> (Int64, Int64) in
            let p = try TestDatabase.insertWorkbench(db)
            return (p, try Self.insertButton(db, workbench: p))
        }
        let vm = makeViewModel()
        vm.refresh()
        let b = try XCTUnwrap(vm.headerButtons(projectID: p).first)
        XCTAssertEqual(Model.action(for: b), .run)
        var opened = 0
        await Model.perform(Model.action(for: b), on: b, vm: vm) { _, _ in opened += 1 }

        XCTAssertEqual(runner.invocations, [["automations", "run", String(id), "--json"]])
        XCTAssertEqual(opened, 0)
        let runs = try await pool.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM automation_runs") }
        XCTAssertEqual(runs, 0, "Swift writes no run; the CLI queues it")
    }

    func testHiddenWhenFeatureOff() {
        let buttons = [button(), button("lint", id: 2)]
        XCTAssertEqual(Model.shown(buttons, featureEnabled: false), [])
        XCTAssertEqual(Model.shown(buttons, featureEnabled: true), buttons)
    }

    // MARK: - View model

    func testHeaderButtonsPerWorkbenchReloadOnRefresh() throws {
        let (p, other) = try pool.write { db -> (Int64, Int64) in
            let p = try TestDatabase.insertWorkbench(db)
            let other = try TestDatabase.insertWorkbench(db, name: "other", folder: "/tmp/other")
            _ = try Self.insertButton(db, slug: "deploy", workbench: p)
            return (p, other)
        }
        let vm = makeViewModel()
        vm.refresh()
        XCTAssertEqual(vm.headerButtons(projectID: p).map(\.slug), ["deploy"])
        XCTAssertEqual(vm.headerButtons(projectID: other), [])

        try pool.write { db in _ = try Self.insertButton(db, slug: "release", workbench: other) }
        vm.refresh()
        XCTAssertEqual(vm.headerButtons(projectID: other).map(\.slug), ["release"])

        try pool.write { db in try db.execute(sql: "UPDATE automations SET removed_at = '2026-10-16T00:00:00Z'") }
        vm.refresh()
        XCTAssertEqual(vm.headerButtons(projectID: p), [])
        XCTAssertEqual(vm.headerButtons(projectID: other), [])
    }

    /// Lifecycle rule: clicked, the owner leaves the workbench while the call
    /// runs in the AppState-owned view model, and coming back shows the
    /// spinner of the queued run.
    func testRunSurvivesNavigation() async throws {
        let (p, id) = try await pool.write { db -> (Int64, Int64) in
            let p = try TestDatabase.insertWorkbench(db)
            return (p, try Self.insertButton(db, workbench: p))
        }
        let pool = try XCTUnwrap(self.pool)
        // The daemon side queues the run from another process.
        runner.whenRun {
            try pool.write { db in _ = try TestDatabase.insertAutomationRun(db, automationID: id, status: "queued") }
        }
        runner.holdRun()
        let vm = makeViewModel()
        vm.refresh()
        let b = try XCTUnwrap(vm.headerButtons(projectID: p).first)

        let task = Task { await Model.perform(Model.action(for: b), on: b, vm: vm) { _, _ in } }
        await waitUntil { self.runner.isHolding }
        XCTAssertTrue(Model.isSpinning(b, busy: vm.busy[id] != nil))

        // Leaving the workbench drops the header view; the view model stays.
        runner.release()
        await task.value

        let back = try XCTUnwrap(vm.headerButtons(projectID: p).first)
        XCTAssertNotNil(back.activeRunID)
        XCTAssertTrue(Model.isSpinning(back, busy: vm.busy[id] != nil))
        XCTAssertEqual(Model.action(for: back), .openRun(try XCTUnwrap(back.activeRunID)))
    }
}
