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
        /// Holds every cwd read until `releaseCwds()`.
        var holdingCwds = false
        var onCwdCall: (() -> Void)?
        var cwdCalls = 0
        private var held: [CheckedContinuation<Void, Never>] = []
        private var heldCwds: [CheckedContinuation<Void, Never>] = []

        func cwdRows() async -> [Int64: SessionAgentCwd] {
            cwdCalls += 1
            onCwdCall?()
            if holdingCwds { await withCheckedContinuation { heldCwds.append($0) } }
            return cwds
        }

        func releaseCwds() {
            holdingCwds = false
            let waiting = heldCwds
            heldCwds = []
            for continuation in waiting { continuation.resume() }
        }

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
        XCTAssertFalse(center.isPlaceStale(sessionID: 1))

        reads.statusError = Failure()
        await center.refreshPlaces(workbenchID: workbenchID).value
        XCTAssertEqual(worktreeName(center.currentPlace(sessionID: 1)), "mobile-a")
        XCTAssertTrue(center.isPlaceStale(sessionID: 1))

        // No verdict (the worktrees could not be listed) is stale too.
        reads.statusError = nil
        reads.scope = .unresolved
        await center.refreshPlaces(workbenchID: workbenchID).value
        XCTAssertEqual(worktreeName(center.currentPlace(sessionID: 1)), "mobile-a")
        XCTAssertTrue(center.isPlaceStale(sessionID: 1))

        // A new cwd that cannot be read is unknown, never the old place.
        reads.statusError = Failure()
        reads.cwds = [1: cwd(1, worktreeB)]
        await center.cwdsMayHaveChanged().value
        XCTAssertEqual(center.currentPlace(sessionID: 1), .unknown)
        XCTAssertTrue(center.isPlaceStale(sessionID: 1))

        reads.statusError = nil
        reads.scope = .worktree
        await center.refreshPlaces(workbenchID: workbenchID).value
        XCTAssertEqual(worktreeName(center.currentPlace(sessionID: 1)), "mobile-b")
        XCTAssertFalse(center.isPlaceStale(sessionID: 1))
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

    /// Fail closed (spec §4): a session that left the main folder for a
    /// worktree not read yet is unknown and stale while git runs, and stays
    /// unknown when that read fails — never the main folder it left.
    func testAMoveToAnUnreadCwdIsUnknownUntilRead() async {
        let reads = Reads()
        reads.cwds = [1: cwd(1, folder)]
        let center = makeCenter(reads)
        await center.followWorkbench(workbenchID, folder: folder).value
        XCTAssertEqual(center.currentPlace(sessionID: 1), .main)
        XCTAssertFalse(center.isPlaceStale(sessionID: 1))

        reads.holding = true
        let called = expectation(description: "B read started")
        reads.onStatusCall = { called.fulfill() }
        reads.cwds = [1: cwd(1, worktreeB)]
        let moved = center.cwdsMayHaveChanged()
        await fulfillment(of: [called], timeout: 5)
        XCTAssertEqual(center.currentPlace(sessionID: 1), .unknown, "pending: not the main folder")
        XCTAssertTrue(center.isPlaceStale(sessionID: 1))

        reads.statusError = Failure()
        reads.release()
        await moved.value
        XCTAssertEqual(center.currentPlace(sessionID: 1), .unknown, "failed: still not the main folder")
        XCTAssertTrue(center.isPlaceStale(sessionID: 1))
    }

    /// Coming back to a page re-reads the places known: the branch may have
    /// moved while the refs watcher was stopped.
    func testFollowingAgainRereadsKnownPlaces() async {
        let reads = Reads()
        reads.cwds = [1: cwd(1, worktreeA)]
        let center = makeCenter(reads)
        await center.followWorkbench(workbenchID, folder: folder).value
        XCTAssertEqual(reads.statusCalls, [worktreeA])
        await center.followWorkbench(workbenchID, folder: folder).value
        XCTAssertEqual(reads.statusCalls, [worktreeA], "still on screen: no re-read")

        center.unfollowWorkbench(workbenchID)
        reads.branches = [worktreeA: "feature/moved"]
        await center.followWorkbench(workbenchID, folder: folder).value
        XCTAssertEqual(reads.statusCalls, [worktreeA, worktreeA])
        XCTAssertEqual(branch(center.currentPlace(sessionID: 1)), "feature/moved")
    }

    /// A read of the cwd a session left lands on nobody: neither on that
    /// session (now in B) nor on another one.
    func testAReadOfALeftCwdDoesNotLand() async {
        let reads = Reads()
        reads.cwds = [1: cwd(1, worktreeA), 2: cwd(2, worktreeB)]
        let center = makeCenter(reads)
        await center.followWorkbench(workbenchID, folder: folder).value

        reads.holding = true
        reads.branches = [worktreeA: "feature/a-moved", worktreeB: "feature/b"]
        let refreshed = expectation(description: "A and B reads started")
        refreshed.expectedFulfillmentCount = 2
        reads.onStatusCall = { refreshed.fulfill() }
        let refresh = center.refreshPlaces(workbenchID: workbenchID)
        await fulfillment(of: [refreshed], timeout: 5)
        reads.onStatusCall = nil

        // Session 1 moves to B while A's read runs.
        reads.cwds = [1: cwd(1, worktreeB), 2: cwd(2, worktreeB)]
        let moved = center.cwdsMayHaveChanged()
        await settle()
        reads.release()
        await refresh.value
        await moved.value
        XCTAssertEqual(worktreeName(center.currentPlace(sessionID: 1)), "mobile-b")
        XCTAssertEqual(worktreeName(center.currentPlace(sessionID: 2)), "mobile-b")
        XCTAssertEqual(branch(center.currentPlace(sessionID: 1)), "feature/b")
        XCTAssertFalse(center.staleCwds.contains { $0.cwd == worktreeA })
    }

    /// Deleted sessions and workbenches leave nothing behind; a stale cwd no
    /// session holds leaves the stale set.
    func testDeletedSessionsAndWorkbenchesAreEvicted() async {
        let reads = Reads()
        reads.cwds = [1: cwd(1, worktreeA), 2: cwd(2, worktreeB)]
        let center = makeCenter(reads)
        await center.followWorkbench(workbenchID, folder: folder).value
        reads.statusError = Failure()
        await center.refreshPlaces(workbenchID: workbenchID).value
        XCTAssertEqual(center.staleCwds.count, 2)

        // Session 2 was deleted.
        reads.cwds = [1: cwd(1, worktreeA)]
        await center.cwdsMayHaveChanged().value
        XCTAssertNil(center.sessionPlaces[2])
        XCTAssertFalse(center.isPlaceStale(sessionID: 2))
        XCTAssertEqual(center.staleCwds.map(\.cwd), [worktreeA])

        center.forgetWorkbench(workbenchID)
        XCTAssertTrue(center.sessionPlaces.isEmpty)
        XCTAssertTrue(center.staleCwds.isEmpty)
        reads.statusCalls = []
        await center.cwdsMayHaveChanged().value
        XCTAssertEqual(reads.statusCalls, [], "a forgotten workbench is not followed")
    }

    /// A cwd read that was running when the workbench was deleted lands on
    /// nothing: no session, no git read.
    func testACwdReadRunningAtForgetDoesNotLand() async {
        let reads = Reads()
        reads.cwds = [1: cwd(1, worktreeA)]
        reads.holdingCwds = true
        let called = expectation(description: "cwd read started")
        reads.onCwdCall = { called.fulfill() }
        let center = makeCenter(reads)
        let read = center.followWorkbench(workbenchID, folder: folder)
        await fulfillment(of: [called], timeout: 5)

        center.forgetWorkbench(workbenchID)
        reads.releaseCwds()
        await read.value
        XCTAssertTrue(center.sessionPlaces.isEmpty)
        XCTAssertFalse(center.isPlaceStale(sessionID: 1))
        XCTAssertEqual(reads.statusCalls, [], "no git read for a deleted workbench")
    }

    /// Coming back, the places are refreshed only after the cwds were read
    /// again: a cwd the session left meanwhile is not read.
    func testFollowingAgainRefreshesOnlyTheCwdsStillHeld() async {
        let reads = Reads()
        reads.cwds = [1: cwd(1, worktreeA)]
        let center = makeCenter(reads)
        await center.followWorkbench(workbenchID, folder: folder).value
        center.unfollowWorkbench(workbenchID)

        reads.cwds = [1: cwd(1, worktreeB)]
        reads.statusCalls = []
        await center.followWorkbench(workbenchID, folder: folder).value
        XCTAssertEqual(reads.statusCalls, [worktreeB], "A was left: only B is read")
        XCTAssertEqual(worktreeName(center.currentPlace(sessionID: 1)), "mobile-b")
    }

    /// A repeated failure does not touch `staleCwds` (no re-render).
    func testARepeatedFailureLeavesTheStaleSetAlone() async {
        let reads = Reads()
        reads.cwds = [1: cwd(1, worktreeA)]
        let center = makeCenter(reads)
        await center.followWorkbench(workbenchID, folder: folder).value
        reads.statusError = Failure()
        await center.refreshPlaces(workbenchID: workbenchID).value
        XCTAssertTrue(center.isPlaceStale(sessionID: 1))

        var changed = false
        withObservationTracking { _ = center.staleCwds } onChange: { changed = true }
        await center.refreshPlaces(workbenchID: workbenchID).value
        XCTAssertFalse(changed)
    }

    /// The state poll re-reads the cwds only when a cwd stamp changed.
    func testStateRowsReadRereadsOnlyOnANewCwdStamp() async {
        let reads = Reads()
        reads.cwds = [1: cwd(1, folder)]
        let center = makeCenter(reads)
        await center.followWorkbench(workbenchID, folder: folder).value
        func row(_ stamp: String?) -> SessionAgentStateRow {
            SessionAgentStateRow(id: 1, projectID: workbenchID, title: "s", agentState: "working",
                                 agentStateAt: nil, workbenchName: "acme", agentCwdAt: stamp)
        }
        await center.stateRowsRead([row("2026-10-12 10:00:00.000")]).value
        reads.cwds = [1: cwd(1, worktreeA)]
        await center.stateRowsRead([row("2026-10-12 10:00:00.000")]).value
        XCTAssertEqual(reads.statusCalls, [], "same stamp: the cwds are not read")

        await center.stateRowsRead([row("2026-10-12 10:00:05.000")]).value
        XCTAssertEqual(reads.statusCalls, [worktreeA])
        XCTAssertEqual(worktreeName(center.currentPlace(sessionID: 1)), "mobile-a")
    }

    /// Lets queued main-actor tasks run.
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(50))
    }
}
