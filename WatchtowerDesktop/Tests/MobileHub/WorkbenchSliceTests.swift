import Foundation
import GRDB
import os
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerSync
import WatchtowerTestSupport

/// The `workbench` projection (mobile POC spec §4.2) and its git status
/// refresher, plus the hidden-column and deleted-workbench rules shared by
/// the three workbench kinds.
final class WorkbenchSliceTests: XCTestCase {
    private var dbPath: String!
    private var dbPool: DatabasePool!
    private let home = "/Users/acme"

    override func setUpWithError() throws {
        (dbPool, dbPath) = try TestDatabase.createPool()
    }

    override func tearDownWithError() throws {
        dbPool = nil
        TestDatabase.cleanup(path: dbPath)
    }

    private func slice(git: @escaping @Sendable (Int64) -> WorkbenchGitSnapshot? = { _ in nil }) -> WorkbenchSlice {
        WorkbenchSlice(home: home, gitStatus: git)
    }

    private func records(_ source: any SliceSource) throws -> [SliceRecord] {
        try dbPool.read { try source.records($0) }
    }

    private func payloads(_ source: any SliceSource) throws -> [[String: Any]] {
        try SliceJSON.objects(try records(source))
    }

    private func onlyPayload(_ source: any SliceSource) throws -> [String: Any] {
        let all = try payloads(source)
        XCTAssertEqual(all.count, 1)
        return try XCTUnwrap(all.first)
    }

    // MARK: - Wire shape

    func testPayloadMatchesTheKitFixture() throws {
        try dbPool.write { db in
            let id = try TestDatabase.insertWorkbench(db, name: "Acme", folder: home + "/Projects/acme")
            try db.execute(sql: "UPDATE projects SET description = ? WHERE id = ?", arguments: [String(repeating: "d", count: 1001), id])
            try SliceSeed.insertSession(db, projectID: id)
        }
        let payload = try onlyPayload(slice { _ in WorkbenchGitSnapshot(branch: "feature/acme-export", detached: false, changes: 3) })

        assertWireShape(
            payload, matches: try SliceJSON.kitFixture("workbench/workbench.json"),
            optionalKeys: ["name_clipped", "description_clipped", "folder_display_clipped", "branch_clipped",
                           "last_session_activity", "targets_more"]
        )
        XCTAssertEqual(payload["description_clipped"] as? Bool, true)
        XCTAssertEqual((payload["description"] as? String)?.count, 1000)
        XCTAssertNil(payload["name_clipped"], "an unclipped field carries no flag key")
        XCTAssertNil(payload["targets_more"], "a board inside its window carries no targets_more")
        XCTAssertEqual(payload["branch"] as? String, "feature/acme-export")
        XCTAssertEqual(payload["changes"] as? Int, 3)
    }

    // MARK: - Hidden columns

    func testHiddenColumnsAreNeverPublished() throws {
        let folder = home + "/Projects/acme"
        try dbPool.write { db in
            let id = try TestDatabase.insertWorkbench(db, folder: folder)
            let target = try TestDatabase.insertWorkbenchTarget(db, projectID: id)
            try TestDatabase.insertWorkbenchComment(db, projectID: id, targetID: target)
            let session = try SliceSeed.insertSession(db, projectID: id, targetID: target, folder: folder)
            try SliceSeed.linkSession(db, sessionID: session, targetID: target)
        }
        let sources: [any SliceSource] = [slice(), WorkbenchTargetSlice(), WorkbenchCommentSlice()]
        var scanned = 0
        for source in sources {
            let records = try dbPool.read { try source.records($0) }
            XCTAssertFalse(records.isEmpty, "\(source.kind) published nothing to scan")
            for record in records {
                scanned += 1
                let keys = SliceJSON.allKeys(try SliceJSON.object(record.payload))
                XCTAssertTrue(keys.isDisjoint(with: neverPublishedKeys), "\(record.recordName): \(keys.intersection(neverPublishedKeys))")
                let text = String(bytes: record.payload, encoding: .utf8) ?? ""
                XCTAssertFalse(text.contains(folder), "\(record.recordName) carries the raw folder path")
            }
        }
        XCTAssertEqual(scanned, 3)
    }

    // MARK: - folder_display

    func testFolderUnderHomeIsShownWithATilde() {
        XCTAssertEqual(WorkbenchBranchPresentation.displayPath(home + "/Projects/acme", home: home), "~/Projects/acme")
        XCTAssertEqual(WorkbenchBranchPresentation.displayPath(home, home: home), "~")
        XCTAssertEqual(WorkbenchBranchPresentation.displayPath(home + "/", home: home + "/"), "~/")
        XCTAssertEqual(
            WorkbenchBranchPresentation.displayPath("/Users/acme2/Projects/acme", home: home), "/Users/acme2/Projects/acme",
            "a sibling folder sharing the prefix is not under home"
        )
    }

    func testFolderOutsideHomeIsShownAsIsAndClippedAt300() throws {
        let long = "/Volumes/acme/" + String(repeating: "x", count: 400)
        try dbPool.write { db in
            try TestDatabase.insertWorkbench(db, name: "a", folder: "/Volumes/acme/Projects/acme")
            try TestDatabase.insertWorkbench(db, name: "b", folder: long)
        }
        let byName = Dictionary(uniqueKeysWithValues: try payloads(slice()).map { ($0["name"] as? String ?? "", $0) })

        XCTAssertEqual(byName["a"]?["folder_display"] as? String, "/Volumes/acme/Projects/acme")
        XCTAssertNil(byName["a"]?["folder_display_clipped"])
        let clipped = try XCTUnwrap(byName["b"]?["folder_display"] as? String)
        XCTAssertEqual(clipped.count, 300)
        XCTAssertTrue(clipped.hasPrefix("/Volumes/acme/"))
        XCTAssertTrue(clipped.hasSuffix("…"))
        XCTAssertEqual(byName["b"]?["folder_display_clipped"] as? Bool, true)
    }

    func testWorkbenchesOrderByParsedSessionActivity() throws {
        let now = Date()
        let whole = dbStamp(now)
        // The same second with a fraction is later, though it sorts lower as text.
        let fractional = String(whole.dropLast()) + ".900Z"
        let (earlier, later, none) = try dbPool.write { db -> (Int64, Int64, Int64) in
            let earlier = try TestDatabase.insertWorkbench(db, name: "a", folder: "/tmp/a")
            let later = try TestDatabase.insertWorkbench(db, name: "b", folder: "/tmp/b")
            let none = try TestDatabase.insertWorkbench(db, name: "c", folder: "/tmp/c")
            try SliceSeed.insertSession(db, projectID: earlier)
            try SliceSeed.insertSession(db, projectID: later)
            try db.execute(sql: "UPDATE terminal_sessions SET last_active_at = ? WHERE project_id = ?", arguments: [whole, earlier])
            try db.execute(sql: "UPDATE terminal_sessions SET last_active_at = ? WHERE project_id = ?", arguments: [fractional, later])
            return (earlier, later, none)
        }
        let order = try dbPool.read { try WorkbenchSlice.publishedWorkbenches($0).map(\.id) }

        XCTAssertEqual(order, [later, earlier, none], "newest activity first, no session last")
    }

    func testAnUnparsableRequiredDateIsLoggedAndPublishedAs1970() {
        let record = "workbench_target-\(UUID().uuidString)"
        XCTAssertEqual(SliceDate.required("not a date", field: "created_at", record: record), Date(timeIntervalSince1970: 0))
        XCTAssertTrue(SliceDate.hasWarned(field: "created_at", record: record))
        XCTAssertFalse(SliceDate.hasWarned(field: "updated_at", record: record))
        XCTAssertEqual(
            SliceDate.required(dbStamp(Date(timeIntervalSince1970: 1_700_000_000)), field: "x", record: record),
            Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertFalse(SliceDate.hasWarned(field: "x", record: record), "a good date logs nothing")
    }

    // MARK: - Zero workbenches

    func testZeroWorkbenchesPublishZeroRecordsAndNoError() async throws {
        let sources: [any SliceSource] = [slice(), WorkbenchTargetSlice(), WorkbenchCommentSlice()]
        for source in sources {
            XCTAssertTrue(try records(source).isEmpty, "\(source.kind)")
        }
        let publisher = SlicePublisher(
            dbPool: dbPool, state: try HubSyncState.inMemory(), transport: StubHubTransport(), sources: sources
        )
        let outcome = try await publisher.publishOnce()
        XCTAssertEqual(outcome, SlicePublisher.Outcome())
    }

    // MARK: - Counts and progress

    func testCountsComeFromTheSwitcherAndDoneCountsOnlyTheUnarchived() throws {
        let now = Date()
        try dbPool.write { db in
            let id = try TestDatabase.insertWorkbench(db)
            try TestDatabase.insertWorkbenchTarget(db, projectID: id, status: "todo")
            try TestDatabase.insertWorkbenchTarget(db, projectID: id, status: "in_progress")
            try TestDatabase.insertWorkbenchTarget(db, projectID: id, status: "blocked")
            let recent = try TestDatabase.insertWorkbenchTarget(db, projectID: id)
            try SliceSeed.close(db, id: recent, at: now.addingTimeInterval(-86_400))
            let old = try TestDatabase.insertWorkbenchTarget(db, projectID: id)
            try SliceSeed.close(db, id: old, at: now.addingTimeInterval(-30 * 86_400))
            try TestDatabase.insertOwnerAsk(db, projectID: id)
        }
        let payload = try onlyPayload(slice())

        XCTAssertEqual(payload["open_targets"] as? Int, 3)
        XCTAssertEqual(payload["in_progress_targets"] as? Int, 1)
        XCTAssertEqual(payload["blocked_targets"] as? Int, 1)
        XCTAssertEqual(payload["open_asks"] as? Int, 1)
        XCTAssertEqual(payload["done_targets"] as? Int, 1, "the done target archived after 14 days is not counted")
        XCTAssertEqual(payload["archive_after_days"] as? Int, 14)
    }

    func testAnEmptyBoardIsZeroOfZero() throws {
        try dbPool.write { db in _ = try TestDatabase.insertWorkbench(db) }
        let payload = try onlyPayload(slice())

        XCTAssertEqual(payload["open_targets"] as? Int, 0)
        XCTAssertEqual(payload["done_targets"] as? Int, 0)
        XCTAssertNil(payload["last_session_activity"], "no session, no activity key")
        XCTAssertEqual(payload["branch"] as? String, "", "no git status read yet")
        XCTAssertEqual(payload["detached"] as? Bool, false)
    }

    func testAtMostAHundredWorkbenchesByLatestSessionActivity() throws {
        let now = Date()
        try dbPool.write { db in
            for index in 0..<101 {
                let id = try TestDatabase.insertWorkbench(db, name: "acme \(index)", folder: "/tmp/acme-\(index)")
                // Workbench 0 is the stalest; every other one is newer.
                try SliceSeed.insertSession(db, projectID: id, lastActiveAt: now.addingTimeInterval(Double(index - 200)))
            }
        }
        let names = Set(try payloads(slice()).compactMap { $0["name"] as? String })

        XCTAssertEqual(names.count, 100)
        XCTAssertFalse(names.contains("acme 0"), "the workbench with the oldest session activity leaves the window")
    }

    // MARK: - Git status

    func testDetachedHeadPublishesAnEmptyBranch() async throws {
        let refresher = makeRefresher { _ in Self.gitStatus(branch: "abc1234", detached: true, changes: 2) }
        await refresher.refreshDue()

        XCTAssertEqual(refresher.status(for: 7), WorkbenchGitSnapshot(branch: "", detached: true, changes: 2))
    }

    func testGitStatusFailureKeepsTheLastBranch() async throws {
        let failing = OSAllocatedUnfairLock(initialState: false)
        let clock = TestInstant()
        let refresher = makeRefresher(clock: clock) { _ in
            if failing.withLock({ $0 }) { throw CLIRunnerError.binaryNotFound }
            return Self.gitStatus(branch: "feature/acme", detached: false, changes: 1)
        }
        await refresher.refreshDue()
        failing.withLock { $0 = true }
        clock.advance(by: .seconds(120))
        let attempted = await refresher.refreshDue()

        XCTAssertEqual(attempted, [7], "the failing run was attempted")
        XCTAssertEqual(refresher.status(for: 7)?.branch, "feature/acme", "a failed run keeps the last value")

        try await dbPool.write { db in _ = try TestDatabase.insertWorkbench(db) }
        let payload = try onlyPayload(slice { _ in refresher.status(for: 7) })
        XCTAssertEqual(payload["branch"] as? String, "feature/acme")
    }

    func testAStatusThatGitItselfCouldNotReadKeepsTheLastValue() async throws {
        let broken = OSAllocatedUnfairLock(initialState: false)
        let clock = TestInstant()
        let refresher = makeRefresher(clock: clock) { _ in
            var status = Self.gitStatus(branch: broken.withLock { $0 } ? "" : "main", detached: false, changes: 4)
            status.statusOK = !broken.withLock { $0 }
            return status
        }
        await refresher.refreshDue()
        broken.withLock { $0 = true }
        clock.advance(by: .seconds(120))
        await refresher.refreshDue()

        XCTAssertEqual(refresher.status(for: 7), WorkbenchGitSnapshot(branch: "main", detached: false, changes: 4))
    }

    func testAHungGitStatusTimesOutAndKeepsTheLastValue() async throws {
        let hangs = OSAllocatedUnfairLock(initialState: false)
        let clock = TestInstant()
        let refresher = makeRefresher(clock: clock, timeout: .milliseconds(50)) { _ in
            if hangs.withLock({ $0 }) { try await Task.sleep(for: .seconds(3600)) }
            return Self.gitStatus(branch: "main", detached: false, changes: 0)
        }
        await refresher.refreshDue()
        hangs.withLock { $0 = true }
        clock.advance(by: .seconds(120))
        await refresher.refreshDue()

        XCTAssertEqual(refresher.status(for: 7)?.branch, "main")
    }

    /// Review I1: a hub stop ends the pass in flight. The blocked run stores
    /// nothing, and no other workbench gets a CLI run after the stop.
    func testAStopEndsThePassAndNoCLIRunsAfterIt() async throws {
        let gate = FetchGate()
        let refresher = WorkbenchGitRefresher(
            fetch: { id in
                await gate.enter(id)
                return Self.gitStatus(branch: "main", detached: false, changes: 0)
            },
            workbenchIDs: { [1, 2, 3] }
        )
        let changes = OSAllocatedUnfairLock(initialState: 0)
        refresher.setOnChange { changes.withLock { $0 += 1 } }
        let pass = Task { await refresher.refreshDue() }
        await awaitHubCondition("the first run is in flight") { gate.calls == [1] }

        refresher.stop()
        gate.release()
        let attempted = await pass.value

        XCTAssertEqual(attempted, [1])
        XCTAssertEqual(gate.calls, [1], "no CLI run after the stop")
        XCTAssertNil(refresher.status(for: 1), "the run in flight at the stop stores nothing")
        XCTAssertEqual(changes.withLock { $0 }, 0, "and nudges nothing")
    }

    func testRefreshCadenceIsEvery120SecondsPerWorkbench() async throws {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let clock = TestInstant()
        let refresher = makeRefresher(clock: clock) { _ in
            calls.withLock { $0 += 1 }
            return Self.gitStatus(branch: "main", detached: false, changes: 0)
        }
        await refresher.refreshDue()
        clock.advance(by: .seconds(119))
        await refresher.refreshDue()
        XCTAssertEqual(calls.withLock { $0 }, 1, "not due before 120 s")

        clock.advance(by: .seconds(1))
        await refresher.refreshDue()
        XCTAssertEqual(calls.withLock { $0 }, 2, "due at 120 s")
    }

    func testASessionStateChangeRefreshesAtMostOncePer30Seconds() async throws {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let clock = TestInstant()
        let refresher = makeRefresher(clock: clock) { _ in
            calls.withLock { $0 += 1 }
            return Self.gitStatus(branch: "main", detached: false, changes: 0)
        }
        await refresher.refreshDue()

        clock.advance(by: .seconds(10))
        refresher.sessionStateChanged(workbenchID: 7)
        await refresher.refreshDue()
        XCTAssertEqual(calls.withLock { $0 }, 1, "a change 10 s after a run waits for the 30 s spacing")

        clock.advance(by: .seconds(20))
        await refresher.refreshDue()
        XCTAssertEqual(calls.withLock { $0 }, 2, "the held change runs once 30 s have passed")

        refresher.sessionStateChanged(workbenchID: 7)
        refresher.sessionStateChanged(workbenchID: 7)
        clock.advance(by: .seconds(30))
        await refresher.refreshDue()
        await refresher.refreshDue()
        XCTAssertEqual(calls.withLock { $0 }, 3, "two changes in one spacing run once")

        refresher.sessionStateChanged(workbenchID: 99)
        clock.advance(by: .seconds(30))
        await refresher.refreshDue()
        XCTAssertEqual(calls.withLock { $0 }, 3, "a change on an unknown workbench runs nothing")
    }

    func testAChangedStatusNotifiesAndAnUnchangedOneDoesNot() async throws {
        let branch = OSAllocatedUnfairLock(initialState: "main")
        let changes = OSAllocatedUnfairLock(initialState: 0)
        let clock = TestInstant()
        let refresher = makeRefresher(clock: clock) { _ in
            Self.gitStatus(branch: branch.withLock { $0 }, detached: false, changes: 0)
        }
        refresher.setOnChange { changes.withLock { $0 += 1 } }

        await refresher.refreshDue()
        clock.advance(by: .seconds(120))
        await refresher.refreshDue()
        XCTAssertEqual(changes.withLock { $0 }, 1, "the first value notifies; the same value again does not")

        branch.withLock { $0 = "feature/acme" }
        clock.advance(by: .seconds(120))
        await refresher.refreshDue()
        XCTAssertEqual(changes.withLock { $0 }, 2)
    }

    func testADeletedWorkbenchIsForgotten() async throws {
        let ids = OSAllocatedUnfairLock<[Int64]>(initialState: [7])
        let refresher = WorkbenchGitRefresher(
            fetch: { _ in Self.gitStatus(branch: "main", detached: false, changes: 0) },
            workbenchIDs: { ids.withLock { $0 } }
        )
        await refresher.refreshDue()
        XCTAssertNotNil(refresher.status(for: 7))

        ids.withLock { $0 = [] }
        await refresher.refreshDue()
        XCTAssertNil(refresher.status(for: 7))
    }

    // MARK: - Review focus 1: a workbench deleted on the Mac

    func testReviewFocus1ADeletedWorkbenchLeavesTheZoneWithItsTargetsAndComments() async throws {
        let (kept, gone) = try await dbPool.write { db -> (Int64, Int64) in
            let kept = try TestDatabase.insertWorkbench(db, name: "kept", folder: "/tmp/kept")
            try TestDatabase.insertWorkbenchTarget(db, projectID: kept)
            let gone = try TestDatabase.insertWorkbench(db, name: "gone", folder: "/tmp/gone")
            let target = try TestDatabase.insertWorkbenchTarget(db, projectID: gone)
            let root = try TestDatabase.insertWorkbenchComment(db, projectID: gone, targetID: target)
            try TestDatabase.insertWorkbenchComment(db, projectID: gone, targetID: target, parentID: root)
            return (kept, gone)
        }
        let state = try HubSyncState.inMemory()
        let transport = StubHubTransport()
        let publisher = SlicePublisher(
            dbPool: dbPool, state: state, transport: transport,
            sources: [slice(), WorkbenchTargetSlice(), WorkbenchCommentSlice()]
        )
        let first = try await publisher.publishOnce()
        XCTAssertEqual(first.pushed, 6)

        try await dbPool.write { db in try db.execute(sql: "DELETE FROM projects WHERE id = ?", arguments: [gone]) }
        let second = try await publisher.publishOnce()

        XCTAssertEqual(second.deleted, 4, "the workbench, its target and both comments")
        XCTAssertEqual(second.pushed, 0)
        let zone = try await transport.changes(in: .data, since: nil)
        XCTAssertEqual(zone.deletedRecordNames.filter { $0.hasPrefix("workbench-") }, ["workbench-\(gone)"])
        XCTAssertEqual(try state.hashes(forKind: .workbench).keys.sorted(), ["workbench-\(kept)"])
        XCTAssertEqual(try state.hashes(forKind: .workbenchComment).count, 0)
    }

    // MARK: - Helpers

    private func makeRefresher(
        clock: TestInstant = TestInstant(),
        timeout: Duration = .seconds(20),
        fetch: @escaping WorkbenchGitRefresher.Fetch
    ) -> WorkbenchGitRefresher {
        let now: @Sendable () -> ContinuousClock.Instant = { clock.now }
        return WorkbenchGitRefresher(
            fetch: fetch,
            workbenchIDs: { [7] },
            timing: .init(every: .seconds(120), minSpacing: .seconds(30), timeout: timeout, wake: .seconds(5)),
            clock: now
        )
    }

    private static func gitStatus(branch: String, detached: Bool, changes: Int) -> WorkbenchGitStatus {
        WorkbenchGitStatus(workbenchID: 7, branch: branch, detached: detached, changes: changes)
    }
}

/// A steerable ContinuousClock instant for cadence tests.
final class TestInstant: Sendable {
    private let current = OSAllocatedUnfairLock(initialState: ContinuousClock.now)

    var now: ContinuousClock.Instant { current.withLock { $0 } }

    func advance(by duration: Duration) {
        current.withLock { $0 += duration }
    }
}

/// A fetch that parks every call until `release()`, recording the ids.
final class FetchGate: Sendable {
    private struct State {
        var calls: [Int64] = []
        var released = false
        var parked: [CheckedContinuation<Void, Never>] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var calls: [Int64] { state.withLock { $0.calls } }

    func enter(_ id: Int64) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = state.withLock { state -> Bool in
                state.calls.append(id)
                guard !state.released else { return true }
                state.parked.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func release() {
        let parked = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.released = true
            defer { state.parked = [] }
            return state.parked
        }
        parked.forEach { $0.resume() }
    }
}
