import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// Where each workbench session's agent works (board #565): places come
/// only from `workbench git status --folder`, read once per cwd and kept on
/// the AppState-owned view model's center. No subprocess: the readers are
/// fakes.
@MainActor
final class SessionPlaceCenterTests: XCTestCase {
    private let workbenchID: Int64 = 1
    private let folder = "/tmp/acme"
    private let worktreeA = "/tmp/acme/.claude/worktrees/mobile-a"
    private let worktreeB = "/tmp/acme/.claude/worktrees/mobile-b"

    /// The fake database and CLI the center reads.
    @MainActor
    final class Reads {
        var cwds: [Int64: SessionAgentCwd] = [:]
        var statusCalls: [String] = []
        var branches: [String: String] = [:]
        var statusError: Error?
        var scope: WorkbenchFolderScope = .worktree
        /// Holds every status read until `release()`.
        var holding = false
        var onStatusCall: (() -> Void)?
        private var held: [CheckedContinuation<Void, Never>] = []

        func cwdRows() -> [Int64: SessionAgentCwd] { cwds }

        func status(_ cwd: String) async throws -> WorkbenchGitStatus {
            statusCalls.append(cwd)
            onStatusCall?()
            if holding { await withCheckedContinuation { held.append($0) } }
            if let statusError { throw statusError }
            return WorkbenchGitStatus(
                branch: branches[cwd] ?? "feature/x", folderRequested: cwd, folderScope: scope,
                folderRoot: scope == .worktree ? cwd : "", worktreeName: scope == .worktree ? (cwd as NSString).lastPathComponent : ""
            )
        }

        func release() {
            holding = false
            let waiting = held
            held = []
            for continuation in waiting { continuation.resume() }
        }
    }

    private struct Failure: Error {}

    private func makeCenter(_ reads: Reads) -> SessionPlaceCenter {
        SessionPlaceCenter(
            readCwds: { _ in await reads.cwdRows() },
            readStatus: { _, cwd in try await reads.status(cwd) },
            isLive: { _ in false }
        )
    }

    private func cwd(_ id: Int64, _ path: String) -> SessionAgentCwd {
        SessionAgentCwd(sessionID: id, path: path, at: "2026-10-12 10:00:00.000")
    }

    private func worktreeName(_ place: SessionPlace) -> String? {
        if case let .worktree(name, _, _) = place { return name }
        return nil
    }

    private func branch(_ place: SessionPlace) -> String? {
        if case let .worktree(_, _, status) = place { return status.branch }
        return nil
    }

    func testAWorktreeCwdIsResolvedOnceAndCached() async {
        let reads = Reads()
        reads.cwds = [1: cwd(1, worktreeA), 2: cwd(2, worktreeA)]
        let center = makeCenter(reads)
        await center.followWorkbench(workbenchID, folder: folder).value
        XCTAssertEqual(reads.statusCalls, [worktreeA], "two sessions in one worktree share one read")
        XCTAssertEqual(worktreeName(center.currentPlace(sessionID: 1)), "mobile-a")
        XCTAssertEqual(worktreeName(center.currentPlace(sessionID: 2)), "mobile-a")

        await center.cwdsMayHaveChanged().value
        await center.cwdsMayHaveChanged().value
        XCTAssertEqual(reads.statusCalls, [worktreeA], "an unchanged cwd is never read again")
    }

    func testAMainFolderCwdRunsNoProcess() async {
        let reads = Reads()
        reads.cwds = [1: cwd(1, folder), 2: cwd(2, folder + "/")]
        let center = makeCenter(reads)
        await center.followWorkbench(workbenchID, folder: folder).value
        await center.refreshPlaces(workbenchID: workbenchID).value
        XCTAssertEqual(reads.statusCalls, [])
        XCTAssertEqual(center.currentPlace(sessionID: 1), .main)
        XCTAssertEqual(center.currentPlace(sessionID: 2), .main)
        XCTAssertEqual(center.currentPlace(sessionID: 3), .unknown, "a session without a cwd is unknown")
    }

    /// A folder inside the workbench folder is not the workbench folder: a
    /// worktree may live there, so it is read.
    func testACwdInsideTheWorkbenchFolderIsRead() async {
        let reads = Reads()
        reads.scope = .main
        reads.cwds = [1: cwd(1, folder + "/sub")]
        let center = makeCenter(reads)
        await center.followWorkbench(workbenchID, folder: folder).value
        XCTAssertEqual(reads.statusCalls, [folder + "/sub"])
        XCTAssertEqual(center.currentPlace(sessionID: 1), .main)
    }

    func testACwdChangeRereadsThePlace() async {
        let reads = Reads()
        reads.cwds = [1: cwd(1, folder)]
        let center = makeCenter(reads)
        await center.followWorkbench(workbenchID, folder: folder).value
        XCTAssertEqual(center.currentPlace(sessionID: 1), .main)

        // The agent entered a worktree: the next hook event stored it.
        reads.cwds = [1: cwd(1, worktreeA)]
        await center.cwdsMayHaveChanged().value
        XCTAssertEqual(reads.statusCalls, [worktreeA])
        XCTAssertEqual(worktreeName(center.currentPlace(sessionID: 1)), "mobile-a")

        // The cwd cleared (a new run before its first report): unknown.
        reads.cwds = [:]
        await center.cwdsMayHaveChanged().value
        XCTAssertEqual(center.currentPlace(sessionID: 1), .unknown)
    }

    func testARefsChangeRefreshesEveryWorktreePlace() async {
        let reads = Reads()
        reads.cwds = [1: cwd(1, worktreeA), 2: cwd(2, worktreeB), 3: cwd(3, folder), 4: cwd(4, worktreeA)]
        let center = makeCenter(reads)
        await center.followWorkbench(workbenchID, folder: folder).value
        XCTAssertEqual(Set(reads.statusCalls), [worktreeA, worktreeB])

        reads.statusCalls = []
        reads.branches = [worktreeA: "feature/y", worktreeB: "feature/z"]
        await center.refreshPlaces(workbenchID: workbenchID).value
        XCTAssertEqual(reads.statusCalls.sorted(), [worktreeA, worktreeB], "one read per worktree cwd, none for the folder")
        XCTAssertEqual(branch(center.currentPlace(sessionID: 1)), "feature/y")
        XCTAssertEqual(branch(center.currentPlace(sessionID: 4)), "feature/y")
        XCTAssertEqual(branch(center.currentPlace(sessionID: 2)), "feature/z")

        // A workbench not on screen is not refreshed.
        center.unfollowWorkbench(workbenchID)
        reads.statusCalls = []
        await center.refreshPlaces(workbenchID: workbenchID).value
        await center.cwdsMayHaveChanged().value
        XCTAssertEqual(reads.statusCalls, [])
    }

    func testAFailedReadKeepsTheLastPlaceStale() async {
        let reads = Reads()
        reads.cwds = [1: cwd(1, worktreeA)]
        let center = makeCenter(reads)
        await center.followWorkbench(workbenchID, folder: folder).value
        XCTAssertFalse(center.isStale(sessionID: 1))

        reads.statusError = Failure()
        await center.refreshPlaces(workbenchID: workbenchID).value
        XCTAssertEqual(worktreeName(center.currentPlace(sessionID: 1)), "mobile-a")
        XCTAssertTrue(center.isStale(sessionID: 1))

        // No verdict (the worktrees could not be listed) is stale too.
        reads.statusError = nil
        reads.scope = .unresolved
        await center.refreshPlaces(workbenchID: workbenchID).value
        XCTAssertEqual(worktreeName(center.currentPlace(sessionID: 1)), "mobile-a")
        XCTAssertTrue(center.isStale(sessionID: 1))

        // A new cwd that cannot be read keeps the last place as well.
        reads.statusError = Failure()
        reads.cwds = [1: cwd(1, worktreeB)]
        await center.cwdsMayHaveChanged().value
        XCTAssertEqual(worktreeName(center.currentPlace(sessionID: 1)), "mobile-a")
        XCTAssertTrue(center.isStale(sessionID: 1))

        reads.statusError = nil
        reads.scope = .worktree
        await center.refreshPlaces(workbenchID: workbenchID).value
        XCTAssertEqual(worktreeName(center.currentPlace(sessionID: 1)), "mobile-b")
        XCTAssertFalse(center.isStale(sessionID: 1))
    }

    /// A worktree whose folder went away is removed, named after the
    /// worktree it was (the last place).
    func testAWorktreeGoneReadsAsRemoved() async {
        let reads = Reads()
        reads.cwds = [1: cwd(1, worktreeA)]
        let center = makeCenter(reads)
        await center.followWorkbench(workbenchID, folder: folder).value
        reads.scope = .missing
        await center.refreshPlaces(workbenchID: workbenchID).value
        XCTAssertEqual(center.currentPlace(sessionID: 1), .removed(name: "mobile-a", path: worktreeA))
    }

    func testPlacesSurviveLeavingThePage() async {
        let reads = Reads()
        reads.cwds = [1: cwd(1, worktreeA)]
        reads.holding = true
        let called = expectation(description: "status read started")
        reads.onStatusCall = { called.fulfill() }
        let center = makeCenter(reads)
        let read = center.followWorkbench(workbenchID, folder: folder)
        await fulfillment(of: [called], timeout: 5)

        // The owner leaves the page while git runs.
        center.unfollowWorkbench(workbenchID)
        reads.release()
        await read.value
        XCTAssertEqual(worktreeName(center.currentPlace(sessionID: 1)), "mobile-a")
    }

    /// No process per refresh: one read per cwd in flight plus one queued.
    func testReadsOfOneCwdAreCoalesced() async {
        let reads = Reads()
        reads.cwds = [1: cwd(1, worktreeA)]
        reads.holding = true
        let called = expectation(description: "status read started")
        reads.onStatusCall = { called.fulfill() }
        let center = makeCenter(reads)
        let first = center.followWorkbench(workbenchID, folder: folder)
        await fulfillment(of: [called], timeout: 5)
        reads.onStatusCall = nil

        let refreshes = (0..<3).map { _ in center.refreshPlaces(workbenchID: workbenchID) }
        XCTAssertEqual(reads.statusCalls, [worktreeA])
        reads.holding = false
        reads.release()
        await first.value
        for refresh in refreshes { await refresh.value }
        XCTAssertEqual(reads.statusCalls, [worktreeA, worktreeA], "the burst costs one rerun")
    }

    /// The center lives on the view model and reads the stored cwd through
    /// the database; the page starting its git watch follows the workbench.
    func testTheViewModelPlacesASessionFromItsStoredCwd() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let worktree = worktreeA
        let (project, sessionID) = try await pool.write { db -> (Workbench, Int64) in
            let id = try TestDatabase.insertWorkbench(db, name: "acme", folder: "/tmp/acme")
            let row = try TerminalSessionQueries.create(db, .init(
                projectID: id, kind: .claude, title: "s", folderPath: "/tmp/acme", claudeSessionID: "uuid-1"
            ))
            try db.execute(
                sql: "UPDATE terminal_sessions SET agent_cwd = ?, agent_cwd_at = '2026-10-12 10:00:00.000' WHERE id = ?",
                arguments: [worktree, row.id]
            )
            return (try XCTUnwrap(WorkbenchQueries.fetch(db, id: id)), row.id)
        }
        let envelope = #"""
            {"workbench_id":\#(project.id),"git":true,"branch":"feature/x","status_ok":true,
             "folder_requested":"\#(worktree)","folder_scope":"worktree","folder_root":"\#(worktree)","worktree_name":"mobile-a"}
            """#
        let runner = ScriptedCLIRunner(results: [.success(Data(envelope.utf8))])
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "SessionPlaceCenterTests-\(UUID().uuidString)"))
        let vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: runner), defaults: defaults)

        await vm.startGitWatching(project: project)
        await vm.sessionPlaces.followWorkbench(project.id, folder: project.folderPath).value
        vm.stopGitWatching(projectID: project.id)

        XCTAssertEqual(worktreeName(vm.sessionPlaces.currentPlace(sessionID: sessionID)), "mobile-a")
        XCTAssertTrue(runner.invocations.contains(
            ["workbench", "git", "status", "--workbench", String(project.id), "--folder", worktree, "--json"]
        ))
        let stored = try await pool.read { try TerminalSessionQueries.fetch($0, id: sessionID) }
        let session = try XCTUnwrap(stored)
        XCTAssertEqual(vm.sessionRows([session]).first?.place?.text, "⑂ mobile-a · feature/x")
    }
}
