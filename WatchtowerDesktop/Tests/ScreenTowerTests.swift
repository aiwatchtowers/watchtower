import GRDB
import ViewInspector
import WatchtowerCore
@testable import WatchtowerDesktop
import WatchtowerInterface
import WatchtowerTestSupport
import XCTest

// #1170 Task 12: every screen writes through the tower. Per screen: a
// refusal shows Go's sentence on its row with Retry; a press with no answer
// (the daemon down) is re-sent by Retry with the same request_id, so a first
// send that did land is answered from the ledger; the screen re-reads after
// an answered press (Go's write is another process's, which no GRDB
// observation sees).

/// Go's sentences the fakes answer with.
private enum Sentences {
    static let changed = "Couldn't update the idea: this idea changed — look again."
    static let busy = "Couldn't change the status: the database is busy."
}

/// The request ids of `tower`'s calls of `command`.
private func requestIDs(_ tower: FakeScreenTower, _ command: TowerCommand) -> [String] {
    tower.calls(command).map(\.requestID)
}

// MARK: - Ideas

@MainActor
final class IdeasViewModelTowerTests: XCTestCase {
    private var manager: DatabaseManager!
    private var path: String!

    override func setUp() async throws {
        (manager, path) = try TestDatabase.createDatabaseManager()
    }

    override func tearDown() async throws {
        TestDatabase.cleanup(path: path)
    }

    private func proposed() throws -> Idea {
        _ = try manager.dbPool.write { try TestDatabase.insertIdea($0, title: "Ship it", status: "proposed") }
        let vm = IdeasViewModel(dbManager: manager)
        vm.load()
        return try XCTUnwrap(vm.reviewItems.first)
    }

    /// Two new ideas saved while the first waits share the create row; the
    /// second goes after the first, never dropped.
    func testTwoCreatesWhileTheFirstWaitsBothLand() async throws {
        let tower = manager.fakeTower
        let (gate, open) = AsyncStream<Void>.makeStream()
        tower.onOK = { _, _ in for await _ in gate { return } }
        let vm = IdeasViewModel(dbManager: manager, tower: tower)

        let first = Task { await vm.createManual(kind: "idea", title: "One", essence: "first") }
        let waiting = await settles { vm.presses.isBusy(IdeasViewModel.createRow) }
        XCTAssertTrue(waiting)
        let second = Task { await vm.createManual(kind: "idea", title: "Two", essence: "second") }
        open.yield()
        let one = await first.value
        open.yield()
        open.finish()
        let two = await second.value

        XCTAssertNotNil(one)
        XCTAssertNotNil(two)
        XCTAssertNotEqual(one, two)
        XCTAssertEqual(tower.calls(.ideasCreate).count, 2)
    }

    /// The same idea pressed again while its create waits is a double press:
    /// it does nothing.
    func testTheSameCreatePressedTwiceWhileItWaitsMakesOneIdea() async throws {
        let tower = manager.fakeTower
        let (gate, open) = AsyncStream<Void>.makeStream()
        tower.onOK = { _, _ in for await _ in gate { return } }
        let vm = IdeasViewModel(dbManager: manager, tower: tower)

        let first = Task { await vm.createManual(kind: "idea", title: "One", essence: "first") }
        let waiting = await settles { vm.presses.isBusy(IdeasViewModel.createRow) }
        XCTAssertTrue(waiting)
        let again = await vm.createManual(kind: "idea", title: "One", essence: "first")
        open.yield()
        open.finish()
        let one = await first.value

        XCTAssertNil(again)
        XCTAssertNotNil(one)
        XCTAssertEqual(tower.calls(.ideasCreate).count, 1)
    }

    func testRefusalShowsTheSentenceAndRetry() async throws {
        let idea = try proposed()
        let tower = manager.fakeTower
        tower.next(.ideasStatus, .refused(Sentences.changed))
        let vm = IdeasViewModel(dbManager: manager, tower: tower)
        vm.load()
        let row = IdeasViewModel.row(idea.id)

        let landed = await vm.approve(idea)

        XCTAssertFalse(landed)
        XCTAssertEqual(vm.presses.state(row), .refused(Sentences.changed))
        XCTAssertEqual(vm.pressFailure(idea), Sentences.changed)
        XCTAssertEqual(vm.reviewItems.map(\.id), [idea.id], "the idea stays as it was")

        await vm.presses.retry(row)

        XCTAssertNil(vm.presses.state(row))
        XCTAssertEqual(tower.calls(.ideasStatus).count, 2, "Retry repeats the press")
        XCTAssertEqual(tower.calls(.ideasStatus).last?.params["status"] as? String, "active")
        XCTAssertEqual(vm.registryItems.first?.status, .active)
    }

    func testRetryAfterNoAnswerResendsTheSameRequestID() async throws {
        let idea = try proposed()
        let tower = manager.fakeTower
        tower.next(.ideasStatus, .failed(TowerText.daemonDown))
        let vm = IdeasViewModel(dbManager: manager, tower: tower)
        vm.load()
        let row = IdeasViewModel.row(idea.id)

        await vm.approve(idea)
        XCTAssertEqual(vm.presses.state(row), .refused(TowerText.daemonDown))
        await vm.presses.retry(row)

        let ids = requestIDs(tower, .ideasStatus)
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(ids.first, ids.last, "Retry re-sends the same request_id")
        XCTAssertNil(vm.presses.state(row))
    }

    func testRefreshesAfterOK() async throws {
        let idea = try proposed()
        let vm = IdeasViewModel(dbManager: manager, tower: manager.fakeTower)
        vm.load()

        await vm.approve(idea)

        XCTAssertTrue(vm.reviewItems.isEmpty, "the list was read again after Go's write")
        XCTAssertEqual(vm.registryItems.map(\.id), [idea.id])
    }

    /// An unknown outcome shows "Didn't confirm — checking again…", re-reads,
    /// and is never re-sent: Retry does nothing.
    func testUnknownOutcomeIsNeverResent() async throws {
        let idea = try proposed()
        let tower = FakeScreenTower()
        tower.next(.ideasStatus, .unknown)
        let vm = IdeasViewModel(dbManager: manager, tower: tower)
        vm.load()
        let row = IdeasViewModel.row(idea.id)

        let screenRead = vm.presses.reread
        var during: String?
        vm.presses.reread = {
            during = vm.pressFailure(idea)
            await screenRead()
        }

        await vm.approve(idea)
        await vm.presses.retry(row)

        XCTAssertEqual(during, TowerText.didntConfirmMac, "the row says so while the screen re-reads")
        XCTAssertNil(vm.presses.state(row), "the re-read settled: the line clears")
        XCTAssertNil(vm.pressFailure(idea))
        XCTAssertEqual(vm.reviewItems.map(\.id), [idea.id], "the row shows what the re-read found")
        XCTAssertEqual(tower.calls(.ideasStatus).count, 1, "never re-sent, not even by Retry")
    }

    /// Made without the app's tower (a test run), a press fails at once with
    /// the daemon's sentence instead of waiting out the client's retries.
    func testWithoutATowerAPressFailsWithTheDaemonsSentence() async throws {
        let idea = try proposed()
        let vm = IdeasViewModel(dbManager: manager)
        vm.load()

        let landed = await vm.approve(idea)

        XCTAssertFalse(landed)
        XCTAssertEqual(vm.presses.state(IdeasViewModel.row(idea.id)), .refused(TowerText.daemonDown))
    }

    /// Idea deletion is Go's `ideas.delete`, which deletes the Discuss chat
    /// too: the Mac writes no chat row.
    func testDeleteSendsIdeasDelete() async throws {
        let idea = try proposed()
        let tower = FakeScreenTower()
        let vm = IdeasViewModel(dbManager: manager, tower: tower)
        vm.load()

        let deleted = await vm.deleteIdea(idea)

        XCTAssertTrue(deleted)
        XCTAssertEqual(tower.calls(.ideasDelete).map { $0.params["id"] as? Int }, [idea.id])
    }
}

// MARK: - Tracks

@MainActor
final class TracksViewModelTowerTests: XCTestCase {
    private var manager: DatabaseManager!
    private var path: String!

    override func setUp() async throws {
        (manager, path) = try TestDatabase.createDatabaseManager()
    }

    override func tearDown() async throws {
        TestDatabase.cleanup(path: path)
    }

    private func track() throws -> Track {
        let id = try manager.dbPool.write { try TestDatabase.insertTrack($0, priority: "medium") }
        return try XCTUnwrap(manager.dbPool.read { try TrackQueries.fetchByID($0, id: Int(id)) })
    }

    func testRefusalShowsTheSentenceAndRetry() async throws {
        let track = try track()
        let tower = manager.fakeTower
        let sentence = "Couldn't change the priority: the database is busy."
        tower.next(.tracksPriority, .refused(sentence))
        let vm = TracksViewModel(dbManager: manager, tower: tower)
        let row = TracksViewModel.row(track.id)

        await vm.updatePriority(track, to: "high")

        XCTAssertEqual(vm.presses.state(row), .refused(sentence))
        XCTAssertEqual(vm.errorMessage, sentence, "the track pane's banner says it too")

        await vm.presses.retry(row)

        XCTAssertNil(vm.presses.state(row))
        XCTAssertEqual(tower.calls(.tracksPriority).map { $0.params["priority"] as? String }, ["high", "high"])
    }

    func testRefreshesAfterOK() async throws {
        let track = try track()
        let vm = TracksViewModel(dbManager: manager, tower: manager.fakeTower)
        vm.load()

        await vm.markRead(track)

        XCTAssertFalse(vm.allTracks.contains { $0.id == track.id }, "read tracks are hidden once the list re-reads")
    }
}

// MARK: - Digests and Decisions

@MainActor
final class DigestViewModelTowerTests: XCTestCase {
    private var manager: DatabaseManager!
    private var path: String!

    override func setUp() async throws {
        (manager, path) = try TestDatabase.createDatabaseManager()
    }

    override func tearDown() async throws {
        TestDatabase.cleanup(path: path)
    }

    private func decision() throws -> Int {
        Int(try manager.dbPool.write { try TestDatabase.insertIdea($0, kind: "decision", title: "Use SQLite", status: "active") })
    }

    func testRefusalShowsTheSentenceAndRetry() async throws {
        let id = try decision()
        let tower = manager.fakeTower
        let sentence = "Couldn't mark it seen: the database is busy."
        tower.next(.ideasDecisionSeen, .refused(sentence))
        let vm = DigestViewModel(dbManager: manager, tower: tower)
        vm.load()
        let row = DigestViewModel.decisionRow(id)

        await vm.markDecisionSeen(id: id)

        XCTAssertEqual(vm.presses.state(row), .refused(sentence))
        XCTAssertEqual(vm.errorMessage, sentence)
        XCTAssertEqual(vm.unreadDecisionCount, 1)

        await vm.presses.retry(row)

        XCTAssertNil(vm.presses.state(row))
        XCTAssertEqual(tower.calls(.ideasDecisionSeen).count, 2)
        XCTAssertEqual(vm.unreadDecisionCount, 0)
    }

    func testRefreshesAfterOK() async throws {
        let id = try decision()
        let vm = DigestViewModel(dbManager: manager, tower: manager.fakeTower)
        vm.load()
        XCTAssertEqual(vm.unreadDecisionCount, 1)

        await vm.markDecisionSeen(id: id)

        XCTAssertEqual(vm.unreadDecisionCount, 0, "the ledger re-read after Go's write")
        XCTAssertNil(vm.errorMessage)
    }
}

// MARK: - Day plan

@MainActor
final class DayPlanViewModelTowerTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!

    override func setUp() async throws {
        (pool, path) = try TestDatabase.createPool()
    }

    override func tearDown() async throws {
        pool = nil
        TestDatabase.cleanup(path: path)
    }

    private func plan(_ tower: FakeScreenTower) async throws -> (DayPlanViewModel, DayPlanItem) {
        try await pool.write { db in
            let plan = try TestDatabase.insertDayPlan(db, planDate: "2026-04-23")
            _ = try TestDatabase.insertDayPlanItem(db, dayPlanID: plan, kind: "backlog", sourceType: "manual", title: "Drink water")
        }
        let vm = DayPlanViewModel(databasePool: pool, cliRunner: FakeCLIRunner(), tower: tower)
        await vm.loadFor(date: "2026-04-23")
        return (vm, try XCTUnwrap(vm.items.first))
    }

    /// Presses on the plan itself (add, reorder) share its row; one made
    /// while another waits goes after it, never dropped.
    func testASecondPlanPressWhileTheFirstWaitsGoesAfterIt() async throws {
        let tower = FakeScreenTower.applying(pool)
        let (gate, open) = AsyncStream<Void>.makeStream()
        tower.onOK = { _, _ in for await _ in gate { return } }
        let (vm, _) = try await plan(tower)

        let first = Task { await vm.addManual(kind: .backlog, title: "Stretch", startTime: nil, endTime: nil) }
        let waiting = await settles { vm.presses.isBusy(DayPlanViewModel.planRow) }
        XCTAssertTrue(waiting)
        let second = Task { await vm.addManual(kind: .backlog, title: "Read", startTime: nil, endTime: nil) }
        open.yield()
        await first.value
        open.yield()
        open.finish()
        await second.value

        XCTAssertEqual(tower.calls(.dayplanAdd).count, 2)
        XCTAssertEqual(Set(vm.items.map(\.title)), ["Drink water", "Stretch", "Read"])
        XCTAssertNil(vm.generationError)
    }

    func testRefusalShowsTheSentenceAndRetry() async throws {
        let tower = FakeScreenTower.applying(pool)
        let sentence = "Couldn't check it off: the database is busy."
        tower.next(.dayplanDone, .refused(sentence))
        let (vm, item) = try await plan(tower)
        let row = DayPlanViewModel.row(item.id)

        await vm.markDone(item)

        XCTAssertEqual(vm.presses.state(row), .refused(sentence), "the item's row says why")
        XCTAssertNil(vm.generationError, "an item's failure stays on its row")
        XCTAssertEqual(vm.items.first?.status, .pending)

        await vm.presses.retry(row)

        XCTAssertNil(vm.presses.state(row))
        XCTAssertEqual(tower.calls(.dayplanDone).count, 2)
        XCTAssertEqual(vm.items.first?.status, .done)
    }

    func testRefreshesAfterOK() async throws {
        let (vm, item) = try await plan(FakeScreenTower.applying(pool))

        await vm.markDone(item)

        XCTAssertEqual(vm.items.first?.status, .done, "the plan re-read after Go's write")
    }
}

// MARK: - Home

@MainActor
final class HomeActionsTowerTests: XCTestCase {
    /// Go's refusal is thrown with its sentence, which Home shows on the row.
    func testRefusalShowsTheSentenceAndRetry() async throws {
        let tower = FakeScreenTower()
        let sentence = "Couldn't change the status: the database is busy."
        tower.next(.targetsSetStatus, .refused(sentence))
        tower.next(.targetsSetStatus, .ok(#"{"rolled_up":[]}"#))
        let performer = LiveHomeFeedPerformer(runner: nil, tower: tower)

        do {
            try await performer.perform(.done, on: .target(4), contentHash: "", now: Date(), calendar: .current)
            XCTFail("a refusal is thrown")
        } catch {
            XCTAssertEqual(error.localizedDescription, sentence)
        }
        // Done again is the row's Retry: the press is sent once more.
        let written = try await performer.perform(.done, on: .target(4), contentHash: "", now: Date(), calendar: .current)

        XCTAssertTrue(written)
        XCTAssertEqual(tower.calls(.targetsSetStatus).count, 2)
    }

    func testRetryAfterNoAnswerResendsTheSameRequestID() async throws {
        let tower = FakeScreenTower()
        tower.next(.remindersDone, .failed(TowerText.daemonDown))
        let performer = LiveHomeFeedPerformer(runner: nil, tower: tower)

        do {
            try await performer.perform(.done, on: .reminder(3), contentHash: "", now: Date(), calendar: .current)
            XCTFail("no answer is a failure")
        } catch {
            XCTAssertEqual(error.localizedDescription, TowerText.daemonDown)
        }
        try await performer.perform(.done, on: .reminder(3), contentHash: "", now: Date(), calendar: .current)

        let ids = requestIDs(tower, .remindersDone)
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(ids.first, ids.last, "Done again re-sends the same request_id")
    }

    /// Home re-reads after an answered press (`HomeCenter.act`): an output
    /// card Go closed leaves the feed; one Go found rewritten (`already`)
    /// comes back for the re-read to show.
    func testRefreshesAfterOK() async throws {
        let tower = FakeScreenTower()
        tower.next(.outputsDone, .ok(#"{"already":true}"#))
        let performer = LiveHomeFeedPerformer(runner: nil, tower: tower)

        let rewritten = try await performer.perform(.done, on: .output(1), contentHash: "h1", now: Date(), calendar: .current)
        let closed = try await performer.perform(.done, on: .output(2), contentHash: "h2", now: Date(), calendar: .current)

        XCTAssertFalse(rewritten, "nothing written: the row comes back and is read again")
        XCTAssertTrue(closed)
    }
}

// MARK: - Catch-Up

@MainActor
final class CatchUpViewModelTowerTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!

    override func setUp() async throws {
        (pool, path) = try TestDatabase.createPool()
        try await pool.write { db in
            try db.execute(sql: "INSERT INTO catchup_recaps (period_from, period_to, status) VALUES (1000, 2000, 'ready')")
        }
    }

    override func tearDown() async throws {
        pool = nil
        TestDatabase.cleanup(path: path)
    }

    func testRefusalShowsTheSentenceAndRetry() async throws {
        let tower = FakeScreenTower.applying(pool)
        let sentence = "Couldn't mark it caught up: the database is busy."
        tower.next(.catchupAcknowledge, .refused(sentence))
        let vm = CatchUpViewModel(dbPool: pool, tower: tower)
        vm.startObserving()
        let selected = await settles { vm.selected != nil }
        XCTAssertTrue(selected)
        let row = CatchUpViewModel.row(try XCTUnwrap(vm.selected).id)

        await vm.acknowledge()

        XCTAssertEqual(vm.presses.state(row), .refused(sentence))
        XCTAssertEqual(vm.selected?.isAcknowledged, false)

        await vm.presses.retry(row)

        XCTAssertNil(vm.presses.state(row))
        XCTAssertEqual(tower.calls(.catchupAcknowledge).count, 2)
        XCTAssertEqual(vm.selected?.isAcknowledged, true)
    }

    func testRefreshesAfterOK() async throws {
        let vm = CatchUpViewModel(dbPool: pool, tower: FakeScreenTower.applying(pool))
        vm.startObserving()
        let selected = await settles { vm.selected != nil }
        XCTAssertTrue(selected)

        await vm.acknowledge()

        XCTAssertEqual(vm.selected?.isAcknowledged, true, "the recap re-read after Go's write")
    }
}

// MARK: - Quick capture

@MainActor
final class QuickCaptureTowerTests: XCTestCase {
    func testRefusalShowsTheSentenceAndRetry() async throws {
        let vm = QuickCaptureViewModel()
        vm.result = DictationCleanResult(title: "Ship it", text: "ship the weekly digest")
        let tower = FakeScreenTower()
        let sentence = "Couldn't save the idea: the database is busy."
        tower.next(.ideasCreate, .refused(sentence))
        tower.next(.ideasCreate, .ok(#"{"id":4}"#))

        await vm.save(tower: tower)

        XCTAssertNil(vm.savedIdeaID)
        XCTAssertEqual(vm.error, "Failed to save idea: \(sentence)")

        await vm.save(tower: tower)

        XCTAssertEqual(vm.savedIdeaID, 4)
        XCTAssertNil(vm.error)
    }

    func testRetryAfterNoAnswerResendsTheSameRequestID() async throws {
        let vm = QuickCaptureViewModel()
        vm.result = DictationCleanResult(title: "Ship it", text: "ship the weekly digest")
        let tower = FakeScreenTower()
        tower.next(.ideasCreate, .failed(TowerText.daemonDown))
        tower.next(.ideasCreate, .ok(#"{"id":4}"#))

        await vm.save(tower: tower)
        await vm.save(tower: tower)

        let ids = requestIDs(tower, .ideasCreate)
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(ids.first, ids.last, "Save again re-sends the same request_id: one idea, never two")
        XCTAssertEqual(vm.savedIdeaID, 4)
    }
}

// MARK: - Targets

@MainActor
final class TargetsViewModelTowerTests: XCTestCase {
    private var manager: DatabaseManager!
    private var path: String!

    override func setUp() async throws {
        (manager, path) = try TestDatabase.createDatabaseManager()
    }

    override func tearDown() async throws {
        TestDatabase.cleanup(path: path)
    }

    private func target() throws -> Target {
        let id = try manager.dbPool.write { try TestDatabase.insertTarget($0, text: "Ship") }
        return try XCTUnwrap(manager.dbPool.read { try TargetQueries.fetchByID($0, id: Int(id)) })
    }

    func testRefusalShowsTheSentenceAndRetry() async throws {
        let target = try target()
        let tower = manager.fakeTower
        tower.next(.targetsSetStatus, .refused(Sentences.busy))
        let vm = TargetsViewModel(dbManager: manager, tower: tower)
        let row = TargetsViewModel.row(target.id)

        let wrote = await vm.markDone(target)

        XCTAssertFalse(wrote)
        XCTAssertEqual(vm.presses.state(row), .refused(Sentences.busy))
        XCTAssertEqual(vm.errorMessage, Sentences.busy)

        await vm.presses.retry(row)

        XCTAssertNil(vm.presses.state(row))
        XCTAssertEqual(tower.calls(.targetsSetStatus).count, 2)
        let stored1 = try await manager.dbPool.read { try TargetQueries.fetchByID($0, id: target.id) }?.status
        XCTAssertEqual(stored1, "done")
    }

    /// A status press waiting on the daemon never holds a local edit of
    /// another target behind it (the edit lands while the press waits).
    func testAStatusPressWaitingOnTheDaemonDoesNotHoldOtherEdits() async throws {
        let pressed = try target()
        let edited = try target()
        let tower = manager.fakeTower
        let (gate, open) = AsyncStream<Void>.makeStream()
        tower.onOK = { _, _ in for await _ in gate { return } }
        let vm = TargetsViewModel(dbManager: manager, tower: tower)

        let press = Task { await vm.markDone(pressed) }
        let waiting = await settles { vm.presses.isBusy(TargetsViewModel.row(pressed.id)) }
        XCTAssertTrue(waiting)
        let wrote = await vm.updateProgress(edited, to: 0.4)

        XCTAssertTrue(wrote, "the edit landed while the press waited")
        XCTAssertTrue(vm.presses.isBusy(TargetsViewModel.row(pressed.id)))
        open.yield()
        open.finish()
        let landed = await press.value
        XCTAssertTrue(landed)
    }

    func testRefreshesAfterOK() async throws {
        let target = try target()
        let vm = TargetsViewModel(dbManager: manager, tower: manager.fakeTower)
        vm.load()
        XCTAssertTrue((vm.todayTargets + vm.allTargets).contains { $0.id == target.id && $0.status == "todo" })

        await vm.updateStatus(target, to: "in_progress")

        XCTAssertEqual((vm.todayTargets + vm.allTargets).first { $0.id == target.id }?.status, "in_progress",
                       "the list re-read after Go's write")
    }

    /// The owner's status is `targets.set_status`; Go's answer names the
    /// parents its rollup moved, and the list is read again so they show.
    func testUpdateStatusSendsSetStatusAndReportsRolledUp() async throws {
        let target = try target()
        let tower = FakeScreenTower()
        tower.next(.targetsSetStatus, .ok(#"{"rolled_up":[1,2]}"#))
        let vm = TargetsViewModel(dbManager: manager, tower: tower)

        let wrote = await vm.updateStatus(target, to: "blocked")

        XCTAssertTrue(wrote)
        let call = try XCTUnwrap(tower.calls(.targetsSetStatus).first)
        XCTAssertEqual(call.params["id"] as? Int, target.id)
        XCTAssertEqual(call.params["status"] as? String, "blocked")
        XCTAssertNil(vm.errorMessage)
        XCTAssertNil(vm.presses.state(TargetsViewModel.row(target.id)))
    }

    func testSnoozeSendsTargetsSnooze() async throws {
        let target = try target()
        let tower = FakeScreenTower()
        tower.next(.targetsSnooze, .ok(#"{"rolled_up":[]}"#))
        let vm = TargetsViewModel(dbManager: manager, tower: tower)
        let until = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-20T12:00:00Z"))

        let wrote = await vm.snooze(target, until: until)

        XCTAssertTrue(wrote)
        let call = try XCTUnwrap(tower.calls(.targetsSnooze).first)
        XCTAssertEqual(call.params["id"] as? Int, target.id)
        XCTAssertEqual(call.params["until"] as? String, TargetsViewModel.snoozeDay(until), "the owner's picked day")
    }
}

@MainActor
final class TargetActionExecutorTowerTests: XCTestCase {
    /// An AI-proposed Done goes through the VM's `updateStatus`
    /// (`targets.set_status`); a refusal leaves the target as it was and
    /// names Go's reason.
    func testDoneGoesThroughSetStatus() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let id = try await manager.dbPool.write { try TestDatabase.insertTarget($0, text: "Ship") }
        let fetched = try await manager.dbPool.read { try TargetQueries.fetchByID($0, id: Int(id)) }
        let target = try XCTUnwrap(fetched)
        let tower = manager.fakeTower
        tower.next(.targetsSetStatus, .refused(Sentences.busy))
        let vm = TargetsViewModel(dbManager: manager, tower: tower)
        let done = ProposedAction(type: .updateStatus, reason: "shipped", status: "done")

        do {
            _ = try await TargetActionExecutor.apply(done, target: target, viewModel: vm)
            XCTFail("a refused write throws")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains(Sentences.busy), "\(error)")
        }
        let stored2 = try await manager.dbPool.read { try TargetQueries.fetchByID($0, id: Int(id)) }?.status
        XCTAssertEqual(stored2, "todo",
                       "the target is as it was")

        let summary = try await TargetActionExecutor.apply(done, target: target, viewModel: vm)

        XCTAssertEqual(summary, "set status to done")
        XCTAssertEqual(tower.calls(.targetsSetStatus).map { $0.params["status"] as? String }, ["done", "done"])
        let stored3 = try await manager.dbPool.read { try TargetQueries.fetchByID($0, id: Int(id)) }?.status
        XCTAssertEqual(stored3, "done")
    }
}

@MainActor
final class TargetsListViewStatusTests: XCTestCase {
    func testStatusMenuSendsSetStatus() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let id = try await manager.dbPool.write { try TestDatabase.insertTarget($0, text: "Ship") }
        let fetched = try await manager.dbPool.read { try TargetQueries.fetchByID($0, id: Int(id)) }
        let target = try XCTUnwrap(fetched)
        let tower = manager.fakeTower
        let vm = TargetsViewModel(dbManager: manager, tower: tower)
        XCTAssertEqual(TargetStatusMenu.title("in_progress"), "In Progress")

        try TargetStatusMenu(target: target, vm: vm).inspect().find(button: "Blocked").tap()
        let settled = await settles { tower.calls.count == 1 && !vm.presses.isBusy(TargetsViewModel.row(target.id)) }
        XCTAssertTrue(settled, "the menu's press reached the tower")

        let call = try XCTUnwrap(tower.calls.first)
        XCTAssertEqual(call.command, .targetsSetStatus)
        XCTAssertEqual(call.params["status"] as? String, "blocked")
        XCTAssertEqual(call.params["id"] as? Int, target.id)
    }
}

@MainActor
final class TargetDetailViewStatusTests: XCTestCase {
    func testStatusPickerSendsSetStatus() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let id = try await manager.dbPool.write { try TestDatabase.insertTarget($0, text: "Ship") }
        let fetched = try await manager.dbPool.read { try TargetQueries.fetchByID($0, id: Int(id)) }
        let target = try XCTUnwrap(fetched)
        let tower = manager.fakeTower
        tower.next(.targetsSetStatus, .refused(Sentences.busy))
        let vm = TargetsViewModel(dbManager: manager, tower: tower)
        let row = TargetsViewModel.row(target.id)
        XCTAssertEqual(TargetStatusBadges.statuses.map(TargetStatusBadges.displayName),
                       ["To Do", "In Progress", "Blocked", "Done"])

        try TargetStatusBadges(target: target, viewModel: vm).inspect().find(button: "Done").tap()
        let settled = await settles { vm.presses.state(row) == .refused(Sentences.busy) }
        XCTAssertTrue(settled, "the badge's press reached the tower")

        XCTAssertEqual(tower.calls.first?.params["status"] as? String, "done")
        // The refusal is drawn under the badges, with Retry.
        let picker = TargetStatusBadges(target: target, viewModel: vm)
        XCTAssertNoThrow(try picker.inspect().find(text: Sentences.busy))
        XCTAssertNoThrow(try picker.inspect().find(button: TowerText.retry))
    }
}
