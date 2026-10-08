import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// A session started on a board target from elsewhere than the owner's
/// screen (the phone, mobile POC spec §6.5): `.background` starts the process
/// and changes nothing the owner sees; `.keeping(.board)` is Work on it.
@MainActor
final class BackgroundStartTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var defaults: UserDefaults!
    private var folder: URL!
    private var processes: [FakeTerminalSession] = []
    private var center: TerminalCenter!

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        defaults = try XCTUnwrap(UserDefaults(suiteName: "BackgroundStartTests-\(UUID().uuidString)"))
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("wt bg \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("acme"), withIntermediateDirectories: true)
        processes = []
        // pid 0: nothing here ever signals a real process group.
        center = TerminalCenter { [weak self] in
            let process = FakeTerminalSession(pid: 0)
            self?.processes.append(process)
            return process
        }
        center.shell = { "/bin/zsh" }
        center.transcriptExists = { _ in true }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    private var acme: String { folder.appendingPathComponent("acme").path }

    private func makeVM() -> WorkbenchesViewModel {
        let vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: FakeCLIRunner()), defaults: defaults,
                                      terminalCenter: center)
        vm.titleService = { _ in .init(title: "", written: false) }
        return vm
    }

    private func workbench() async throws -> Int64 {
        let acme = acme
        return try await pool.write { try TestDatabase.insertWorkbench($0, name: "acme", folder: acme) }
    }

    private func target(_ projectID: Int64, _ text: String = "Ship it") async throws -> Int64 {
        try await pool.write { try TestDatabase.insertWorkbenchTarget($0, projectID: projectID, text: text) }
    }

    private func insertSession(_ projectID: Int64, title: String, targetID: Int64? = nil) async throws -> TerminalSession {
        let acme = acme
        return try await pool.write {
            try TerminalSessionQueries.create($0, .init(
                projectID: projectID, kind: .claude, title: title, targetID: targetID, folderPath: acme,
                claudeSessionID: UUID().uuidString.lowercased()
            ))
        }
    }

    private func rows(_ projectID: Int64) async throws -> [TerminalSession] {
        try await pool.read { try TerminalSessionQueries.fetchForWorkbench($0, projectID: projectID) }
    }

    private var launches: [TerminalLaunch] { processes.flatMap(\.launches) }

    /// The owner's page: workbench `p` selected with session `shown` on screen.
    private func page(_ vm: WorkbenchesViewModel, _ p: Int64, showing shown: TerminalSession) async {
        await vm.reload()
        vm.selectedWorkbenchID = p
        await vm.loadSessions(projectID: p)
        await vm.showSession(id: shown.id)
    }

    // MARK: - Background

    func testABackgroundStartLeavesTheScreenAloneAndRunsTheProcess() async throws {
        let p = try await workbench()
        let t = try await target(p)
        let shown = try await insertSession(p, title: "shown")
        let vm = makeVM()
        await page(vm, p, showing: shown)
        let focusBefore = center.focusOrder
        let layoutBefore = vm.layout(projectID: p)

        let row = try await vm.startForTarget(targetID: t, prompt: nil, mode: .new, placement: .background)

        XCTAssertEqual(center.focusOrder, focusBefore)
        XCTAssertEqual(vm.selectedWorkbenchID, p)
        XCTAssertEqual(vm.layout(projectID: p), layoutBefore)
        XCTAssertEqual(vm.layout(projectID: p).primary, .session(shown.id))
        XCTAssertEqual(center.states[row.id], .running, "the process runs without a pane")
        XCTAssertEqual(row.targetID, t)
        XCTAssertEqual(row.title, "Ship it")
        XCTAssertEqual(launches.last?.environment.last,
                       "WATCHTOWER_FIRST_PROMPT=\(TerminalLaunch.workOnTargetPrompt(targetID: t, vocabulary: .current))")
        let stored = try await rows(p)
        XCTAssertTrue(stored.contains { $0.id == row.id }, "the row is in its workbench's list")
        XCTAssertTrue(vm.terminalSessions[p]?.contains { $0.id == row.id } == true, "and the panel's list is refreshed")
    }

    /// The owner clicks another session (a slow switch: the row is not in the
    /// loaded list yet) and a background start lands meanwhile: the owner's
    /// click still decides what is on screen.
    func testABackgroundStartDuringAnOwnersSwitchDoesNotChangeWhatTheOwnerSees() async throws {
        let p = try await workbench()
        let t = try await target(p)
        let shown = try await insertSession(p, title: "shown")
        let vm = makeVM()
        await page(vm, p, showing: shown)
        let next = try await insertSession(p, title: "next")

        let owner = Task { await vm.showSession(id: next.id) }
        let phone = Task { try await vm.startForTarget(targetID: t, prompt: nil, mode: .new, placement: .background) }
        await owner.value
        let started = try await phone.value

        XCTAssertEqual(vm.layout(projectID: p).primary, .session(next.id))
        XCTAssertEqual(vm.panelSelection, .session(next.id))
        XCTAssertEqual(center.focusOrder.last, next.id)
        XCTAssertEqual(center.states[started.id], .running)
        XCTAssertNil(vm.sessionErrors[p])
    }

    // MARK: - Bring forward

    /// `.keeping(.board)` is the Desktop's Work on it: the session is focused
    /// and goes beside the board.
    func testKeepingTheBoardBehavesAsWorkOnIt() async throws {
        let p = try await workbench()
        let t = try await target(p)
        let vm = makeVM()
        await vm.reload()
        vm.selectedWorkbenchID = p

        let row = try await vm.startForTarget(targetID: t, prompt: nil, mode: .openExisting, placement: .keeping(.board))

        XCTAssertEqual(center.focusOrder.last, row.id)
        XCTAssertEqual(vm.layout(projectID: p).primary, .session(row.id))
        XCTAssertEqual(center.states[row.id], .running)
        XCTAssertEqual(launches.count, 1)
    }

    // MARK: - Modes

    func testOpenExistingOpensTheTargetsSessionWithoutANewRow() async throws {
        let p = try await workbench()
        let t = try await target(p)
        let existing = try await insertSession(p, title: "Ship it", targetID: t)
        let vm = makeVM()

        let row = try await vm.startForTarget(targetID: t, prompt: "ignored", mode: .openExisting, placement: .background)

        XCTAssertEqual(row.id, existing.id)
        let stored = try await rows(p)
        XCTAssertEqual(stored.count, 1, "no new row")
        let uuid = try XCTUnwrap(existing.claudeSessionID)
        XCTAssertEqual(launches.map(\.args.last), ["exec claude --resume \(uuid)"], "it resumes")
        XCTAssertEqual(center.states[existing.id], .running)
        XCTAssertTrue(center.focusOrder.isEmpty)
    }

    func testNewAlwaysCreatesARow() async throws {
        let p = try await workbench()
        let t = try await target(p)
        let existing = try await insertSession(p, title: "Ship it", targetID: t)
        let vm = makeVM()

        let row = try await vm.startForTarget(targetID: t, prompt: nil, mode: .new, placement: .background)

        XCTAssertNotEqual(row.id, existing.id)
        let stored = try await rows(p)
        XCTAssertEqual(stored.filter { $0.targetID == t }.count, 2)
        XCTAssertEqual(center.states[row.id], .running)
    }

    // MARK: - The brief

    func testPlanFirstAppendsExactlyTheSuffix() async throws {
        XCTAssertEqual(TerminalLaunch.planFirstSuffix,
                       "Plan first: put the plan on the board, then ask me with ask_owner before you change any code.")
        let p = try await workbench()
        let t = try await target(p)
        let vm = makeVM()

        _ = try await vm.startForTarget(targetID: t, prompt: nil, mode: .new, placement: .background, planFirst: true)
        _ = try await vm.startForTarget(targetID: t, prompt: "Fix the login", mode: .new, placement: .background,
                                        planFirst: true)

        let base = TerminalLaunch.workOnTargetPrompt(targetID: t, vocabulary: .current)
        XCTAssertEqual(launches.map { $0.environment.last }, [
            "WATCHTOWER_FIRST_PROMPT=\(base) \(TerminalLaunch.planFirstSuffix)",
            "WATCHTOWER_FIRST_PROMPT=Fix the login \(TerminalLaunch.planFirstSuffix)"
        ])
    }

    /// The brief goes through Work on it's argv path: in the environment,
    /// never in argv, with a leading "-" kept from reading as a flag.
    func testABriefStartingWithADashReachesTheLaunchIntact() async throws {
        let p = try await workbench()
        let t = try await target(p)
        let vm = makeVM()

        let row = try await vm.startForTarget(targetID: t, prompt: "--dangerously-skip-permissions please",
                                              mode: .new, placement: .background)

        let launch = try XCTUnwrap(launches.last)
        let uuid = try XCTUnwrap(row.claudeSessionID)
        XCTAssertEqual(launch.args.last,
                       "exec /bin/sh -c 'exec env -u WATCHTOWER_FIRST_PROMPT claude --session-id \(uuid) \"$WATCHTOWER_FIRST_PROMPT\"'")
        XCTAssertEqual(launch.environment.last, "WATCHTOWER_FIRST_PROMPT= --dangerously-skip-permissions please")
    }

    // MARK: - Failures

    func testATargetNotOnABoardFailsNotOnBoard() async throws {
        let loose = try await pool.write { try TestDatabase.insertTarget($0, text: "Loose") }
        let vm = makeVM()

        do {
            _ = try await vm.startForTarget(targetID: loose, prompt: nil, mode: .new, placement: .background)
            XCTFail("expected notOnBoard")
        } catch let error as WorkbenchesViewModel.TargetStartError {
            XCTAssertEqual(error, .notOnBoard)
        }
        XCTAssertTrue(launches.isEmpty)
    }
}
