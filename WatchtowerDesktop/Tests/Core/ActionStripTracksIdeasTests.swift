import Foundation
import GRDB
import XCTest
import WatchtowerTestSupport
@testable import WatchtowerCore

/// Track my threads and Idea finder as the Inbox view model serves them
/// (phase 3): their root entries open their own panes, never a legacy list;
/// a news thread opened in the pane; the idea batch fixed per local day in
/// UserDefaults; **Stop Tracking Quiet Ones…** through `watchtower tracks
/// dismiss` and **Clear Old Ideas…** through one GRDB write; the root rows'
/// news and batch rules.
@MainActor
final class ActionStripTracksIdeasTests: XCTestCase {
    private var pool: DatabasePool!
    private var path = ""
    private var suite = ""
    private var defaults: UserDefaults!
    private let clock = TestClock()

    override func setUp() async throws {
        (pool, path) = try TestDatabase.createPool()
        suite = "ActionStripTracksIdeasTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date()) ?? Date()
        clock.set(noon)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        pool = nil
        TestDatabase.cleanup(path: path)
    }

    /// A settable clock for the view model.
    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date()

        func set(_ date: Date) { lock.withLock { value = date } }
        func now() -> Date { lock.withLock { value } }
    }

    /// A runner whose every `capture` is `answer(args)`, recorded in order.
    private final class ScriptedRunner: CLIRunnerProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [[String]] = []
        private let answer: @Sendable ([String]) async throws -> CLICapturedResult

        init(_ answer: @escaping @Sendable ([String]) async throws -> CLICapturedResult) {
            self.answer = answer
        }

        var invocations: [[String]] { lock.withLock { recorded } }

        func run(args: [String]) async throws -> Data {
            try await capture(args: args, timeout: 0).stdout
        }

        func capture(args: [String], timeout: TimeInterval) async throws -> CLICapturedResult {
            lock.withLock { recorded.append(args) }
            return try await answer(args)
        }
    }

    private func makeVM(runner: (any CLIRunnerProtocol)? = FakeCLIRunner()) -> ActionStripViewModel {
        let clock = clock
        return ActionStripViewModel(
            dbPool: pool, cliRunner: runner, defaults: defaults, clock: { clock.now() },
            findCLI: { nil }, dayChangeSignals: [])
    }

    nonisolated private static func stamp(_ now: Date, daysAgo days: Double) -> String {
        AutomationDates.format(now.addingTimeInterval(-days * 24 * 3600))
    }

    /// A track whose last event is `daysAgo` before `now`.
    @discardableResult
    nonisolated private static func track(_ now: Date, _ text: String, daysAgo: Double, db: Database) throws -> Int64 {
        let id = try TestDatabase.insertTrack(db, text: text)
        try db.execute(sql: "UPDATE tracks SET updated_at = ?, created_at = ? WHERE id = ?",
                       arguments: [stamp(now, daysAgo: daysAgo), stamp(now, daysAgo: daysAgo), id])
        return id
    }

    /// An idea awaiting a verdict, created `daysAgo` before `now`.
    nonisolated private static func idea(_ now: Date, _ title: String, daysAgo: Double, db: Database) throws -> Int {
        Int(try TestDatabase.insertIdea(
            db, title: title, createdAt: stamp(now, daysAgo: daysAgo), updatedAt: stamp(now, daysAgo: daysAgo)))
    }

    private func dismissedAt(_ ids: [Int64]) async throws -> [String] {
        try await pool.read { db in
            try ids.map { id in
                try String.fetchOne(db, sql: "SELECT dismissed_at FROM tracks WHERE id = ?", arguments: [id]) ?? ""
            }
        }
    }

    nonisolated private static func json(_ text: String) -> CLICapturedResult {
        CLICapturedResult(stdout: Data(text.utf8), exitCode: 0)
    }

    // MARK: - Panes, not legacy lists

    func testSelectingTrackMyThreadsShowsPaneWithoutLegacyList() async throws {
        let now = clock.now()
        let trackID = try await pool.write { db in
            try InboxFolderFixtures.seed(db)
            return try Self.track(now, "Release acme 2.0 checklist", daysAgo: 0.1, db: db)
        }
        let vm = makeVM()
        await vm.refresh()

        await vm.selectEntry("tracks")

        XCTAssertEqual(vm.entrySelection, "tracks")
        XCTAssertNil(vm.legacyList)
        XCTAssertNil(vm.selection)
        let readAt = try await pool.read { db in
            try String.fetchOne(db, sql: "SELECT read_at FROM tracks WHERE id = ?", arguments: [trackID])
        }
        XCTAssertNil(readAt, "selecting the entry marks nothing read")
    }

    func testSelectingIdeaFinderShowsPaneWithoutLegacyList() async throws {
        let now = clock.now()
        let ideaID = try await pool.write { db in
            try InboxFolderFixtures.seed(db)
            return try Self.idea(now, "A shared glossary", daysAgo: 2, db: db)
        }
        let vm = makeVM()
        await vm.refresh()

        await vm.selectEntry("ideas")

        XCTAssertEqual(vm.entrySelection, "ideas")
        XCTAssertNil(vm.legacyList)
        let seenAt = try await pool.read { db in
            try String.fetchOne(db, sql: "SELECT seen_at FROM ideas WHERE id = ?", arguments: [ideaID])
        }
        XCTAssertNil(seenAt, "selecting the entry marks nothing seen")
    }

    func testRouteToLegacyTracksSelectsEntry() async throws {
        let now = clock.now()
        let root = try await pool.write { db in
            let folders = try InboxFolderFixtures.seed(db)
            try Self.track(now, "Release acme 2.0 checklist", daysAgo: 0.1, db: db)
            return folders.root
        }
        let vm = makeVM()
        await vm.refresh()

        await vm.open(folder: nil, select: .legacy(.tracks))

        XCTAssertEqual(vm.folderMenu.selectedFolderID, root)
        XCTAssertEqual(vm.entrySelection, "tracks")
        XCTAssertNil(vm.legacyList)
    }

    func testOpenedNewsTrackClosesWhenTrackLeavesActiveList() async throws {
        let now = clock.now()
        let id = try await pool.write { db in
            try InboxFolderFixtures.seed(db)
            return try Self.track(now, "Release acme 2.0 checklist", daysAgo: 0.1, db: db)
        }
        let vm = makeVM()
        await vm.refresh()
        await vm.selectEntry("tracks")

        vm.openNewsTrack(Int(id))
        XCTAssertEqual(vm.openedNewsTrackID, Int(id))
        XCTAssertEqual(vm.openedNewsTrack?.track.id, Int(id))

        try await pool.write { db in
            try db.execute(sql: "UPDATE tracks SET dismissed_at = ? WHERE id = ?", arguments: [Self.stamp(now, daysAgo: 0), id])
        }
        await vm.refresh()

        XCTAssertNil(vm.openedNewsTrackID)
        XCTAssertNil(vm.openedNewsTrack)
    }

    func testOpenedNewsTrackResetsOnNavigation() async throws {
        let now = clock.now()
        let id = try await pool.write { db in
            try InboxFolderFixtures.seed(db)
            return try Self.track(now, "Release acme 2.0 checklist", daysAgo: 0.1, db: db)
        }
        let vm = makeVM()
        await vm.refresh()
        await vm.selectEntry("tracks")

        vm.openNewsTrack(Int(id))
        vm.closeNewsTrack()
        XCTAssertNil(vm.openedNewsTrackID)

        vm.openNewsTrack(Int(id))
        await vm.selectEntry("tracks")
        XCTAssertNil(vm.openedNewsTrackID, "selectEntry")

        vm.openNewsTrack(Int(id))
        vm.selectFolder(vm.folderMenu.tree.root.id)
        await vm.arrival?.value
        XCTAssertNil(vm.openedNewsTrackID, "selectFolder")

        vm.openNewsTrack(Int(id))
        await vm.open(folder: nil, select: .legacy(.tracks))
        XCTAssertNil(vm.openedNewsTrackID, "open(folder:select:)")
    }

    // MARK: - The daily batch

    func testFirstReadOfDayStoresBatchAndLaterReadsKeepIt() async throws {
        let now = clock.now()
        defaults.set(2, forKey: IdeaDailyBatch.sizeKey)
        let ids = try await pool.write { db in
            try InboxFolderFixtures.seed(db)
            return [try Self.idea(now, "One", daysAgo: 5, db: db), try Self.idea(now, "Two", daysAgo: 4, db: db),
                    try Self.idea(now, "Three", daysAgo: 3, db: db)]
        }
        let vm = makeVM()
        await vm.refresh()

        XCTAssertEqual(vm.ideaBatch.batchIDs, [ids[0], ids[1]])
        XCTAssertEqual(defaults.array(forKey: IdeaDailyBatch.idsKey) as? [Int], [ids[0], ids[1]])
        XCTAssertNotNil(defaults.string(forKey: IdeaDailyBatch.dateKey))

        // An older candidate arrives the same day: the batch stays.
        let older = try await pool.write { db in try Self.idea(now, "Older", daysAgo: 10, db: db) }
        await vm.refresh()
        XCTAssertEqual(vm.ideaBatch.batchIDs, [ids[0], ids[1]])
        XCTAssertEqual(vm.ideaBatch.backlogCount, 2)

        vm.takeNextIdeaBatch()
        XCTAssertEqual(vm.ideaBatch.batchIDs, [older, ids[0]], "Next hands out the oldest candidates now")
        XCTAssertEqual(defaults.array(forKey: IdeaDailyBatch.idsKey) as? [Int], [older, ids[0]])
    }

    func testReadAfterMidnightPicksNewBatch() async throws {
        let now = clock.now()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: clock.now())
        let lateEvening = try XCTUnwrap(calendar.date(bySettingHour: 23, minute: 59, second: 0, of: today))
        let tomorrow = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: today))
        let afterMidnight = try XCTUnwrap(calendar.date(bySettingHour: 0, minute: 1, second: 0, of: tomorrow))
        clock.set(lateEvening)
        defaults.set(2, forKey: IdeaDailyBatch.sizeKey)
        let ids = try await pool.write { db in
            try InboxFolderFixtures.seed(db)
            return try (0..<4).map { try Self.idea(now, "Idea \($0)", daysAgo: Double(6 - $0), db: db) }
        }
        let vm = makeVM()
        await vm.refresh()
        let firstDay = defaults.string(forKey: IdeaDailyBatch.dateKey)
        XCTAssertEqual(vm.ideaBatch.batchIDs, [ids[0], ids[1]])

        // The first two judged before midnight.
        try await pool.write { db in
            try db.execute(sql: "UPDATE ideas SET status = 'active' WHERE id IN (?, ?)", arguments: [ids[0], ids[1]])
        }
        clock.set(afterMidnight)
        await vm.refresh()

        XCTAssertNotEqual(defaults.string(forKey: IdeaDailyBatch.dateKey), firstDay)
        XCTAssertNotNil(defaults.string(forKey: IdeaDailyBatch.dateKey))
        XCTAssertEqual(vm.ideaBatch.batchIDs, [ids[2], ids[3]])
        XCTAssertEqual(defaults.array(forKey: IdeaDailyBatch.idsKey) as? [Int], [ids[2], ids[3]])
    }

    // MARK: - Stop Tracking Quiet Ones…

    func testStopTrackingQuietRunsDryRunThenExactIDs() async throws {
        let now = clock.now()
        let ids = try await pool.write { db in
            try InboxFolderFixtures.seed(db)
            return [try Self.track(now, "Old vendor thread", daysAgo: 40, db: db),
                    try Self.track(now, "Old budget thread", daysAgo: 45, db: db),
                    try Self.track(now, "Fresh thread", daysAgo: 0.1, db: db)]
        }
        let pool = try XCTUnwrap(pool)
        let planned = [ids[0], ids[1]]
        let runner = ScriptedRunner { args in
            if args.contains("--dry-run") {
                return Self.json(#"{"count":2,"ids":[\#(planned[0]),\#(planned[1])]}"#)
            }
            try await pool.write { db in
                try db.execute(sql: "UPDATE tracks SET dismissed_at = '2026-01-01T00:00:00Z' WHERE id IN (?, ?)",
                               arguments: [planned[0], planned[1]])
            }
            return Self.json(#"{"dismissed":2,"skipped":0,"ids":[\#(planned[0]),\#(planned[1])]}"#)
        }
        let vm = makeVM(runner: runner)
        await vm.refresh()
        XCTAssertEqual(vm.feed.tracks.count, 3)

        let plan = try await vm.planQuietTracks()
        XCTAssertEqual(plan, InboxBulkPlan(ids: planned.map(String.init), count: 2))
        let result = await vm.stopTrackingQuiet(plan.ids)

        XCTAssertEqual(result, .done(count: 2, skipped: 0))
        XCTAssertEqual(runner.invocations, [
            TracksBulkCLI.dryRunArgs(quietDays: 30), TracksBulkCLI.dismissArgs(ids: plan.ids)
        ])
        XCTAssertEqual(vm.feed.tracks.map(\.track.id), [Int(ids[2])], "the read after the apply")
    }

    func testStopTrackingQuietFailureReportsCLIText() async throws {
        let now = clock.now()
        let ids = try await pool.write { db in
            try InboxFolderFixtures.seed(db)
            return [try Self.track(now, "Old vendor thread", daysAgo: 40, db: db),
                    try Self.track(now, "Old budget thread", daysAgo: 45, db: db)]
        }
        let runner = ScriptedRunner { _ in
            CLICapturedResult(
                stdout: Data(#"{"dismissed":0,"of":2,"error":"database is locked"}"#.utf8), exitCode: 1,
                stderr: "database is locked")
        }
        let vm = makeVM(runner: runner)
        await vm.refresh()

        let result = await vm.stopTrackingQuiet(ids.map(String.init))

        XCTAssertEqual(result, .failed("database is locked"))
        let dismissed = try await dismissedAt(ids)
        XCTAssertEqual(dismissed, ["", ""])
        XCTAssertEqual(vm.feed.tracks.count, 2)
    }

    func testStopTrackingQuietTimeoutAfterCommitReportsWhatStopped() async throws {
        let now = clock.now()
        let ids = try await pool.write { db in
            try InboxFolderFixtures.seed(db)
            return [try Self.track(now, "Old vendor thread", daysAgo: 40, db: db),
                    try Self.track(now, "Old budget thread", daysAgo: 45, db: db)]
        }
        let pool = try XCTUnwrap(pool)
        let committed = ScriptedRunner { _ in
            try await pool.write { db in
                try db.execute(sql: "UPDATE tracks SET dismissed_at = '2026-01-01T00:00:00Z' WHERE id IN (?, ?)",
                               arguments: [ids[0], ids[1]])
            }
            throw CLIRunnerError.nonZeroExit(code: -1, stderr: "")
        }
        let vm = makeVM(runner: committed)
        await vm.refresh()

        let result = await vm.stopTrackingQuiet(ids.map(String.init))

        XCTAssertEqual(result, .partial(done: 2, of: 2, error: TracksBulkCLI.timeoutMessage))
        XCTAssertTrue(vm.feed.tracks.isEmpty, "the read after the apply")

        // Nothing written before the timeout: the failure as is.
        try await pool.write { db in try db.execute(sql: "UPDATE tracks SET dismissed_at = ''") }
        let lost = ScriptedRunner { _ in throw CLIRunnerError.nonZeroExit(code: -1, stderr: "") }
        let other = makeVM(runner: lost)
        await other.refresh()
        let failed = await other.stopTrackingQuiet(ids.map(String.init))
        XCTAssertEqual(failed, .failed(TracksBulkCLI.timeoutMessage))
    }

    // MARK: - Clear Old Ideas…

    func testClearOldIdeasSkipsIdeasJudgedMeanwhile() async throws {
        let now = clock.now()
        let ids = try await pool.write { db in
            try InboxFolderFixtures.seed(db)
            let old = try (0..<3).map { try Self.idea(now, "Old \($0)", daysAgo: 40 + Double($0), db: db) }
            _ = try Self.idea(now, "Fresh", daysAgo: 2, db: db)
            return old
        }
        let vm = makeVM()
        await vm.refresh()

        let plan = try await vm.planOldIdeas()
        XCTAssertEqual(Set(plan.ids), Set(ids.map(String.init)))
        XCTAssertEqual(plan.count, 3)

        try await pool.write { db in
            try db.execute(sql: "UPDATE ideas SET status = 'active' WHERE id = ?", arguments: [ids[1]])
        }
        let result = await vm.clearOldIdeas(plan.ids)

        XCTAssertEqual(result, .done(count: 2, skipped: 1))
        let statuses = try await pool.read { db in
            try ids.map { try String.fetchOne(db, sql: "SELECT status FROM ideas WHERE id = ?", arguments: [$0]) }
        }
        XCTAssertEqual(statuses, ["dropped", "active", "dropped"])
        XCTAssertEqual(vm.ideaBatch.olderCount, 0, "the read after the write")
    }

    // MARK: - The presses

    /// Waits (bounded) for `model` to reach a state `done` accepts.
    private func settle(_ model: InboxBulkPressModel, _ done: (InboxBulkPressModel.State) -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while !done(model.state), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func testPressModelsPlanAndApplyThroughTheModel() async throws {
        let now = clock.now()
        let (tracks, ideas) = try await pool.write { db in
            try InboxFolderFixtures.seed(db)
            let tracks = [try Self.track(now, "Old vendor thread", daysAgo: 40, db: db)]
            let ideas = [try Self.idea(now, "Old one", daysAgo: 40, db: db)]
            return (tracks, ideas)
        }
        let pool = try XCTUnwrap(pool)
        let runner = ScriptedRunner { args in
            if args.contains("--dry-run") { return Self.json(#"{"count":1,"ids":[\#(tracks[0])]}"#) }
            try await pool.write { db in
                try db.execute(sql: "UPDATE tracks SET dismissed_at = '2026-01-01T00:00:00Z' WHERE id = ?",
                               arguments: [tracks[0]])
            }
            return Self.json(#"{"dismissed":1,"skipped":0,"ids":[\#(tracks[0])]}"#)
        }
        let vm = makeVM(runner: runner)
        await vm.refresh()

        vm.quietTracksPress.begin()
        await settle(vm.quietTracksPress) { if case .confirming = $0 { true } else { false } }
        XCTAssertEqual(vm.quietTracksPress.state, .confirming(InboxBulkPlan(ids: [String(tracks[0])], count: 1)))
        vm.quietTracksPress.confirm()
        await settle(vm.quietTracksPress) { if case .finished = $0 { true } else { false } }
        XCTAssertEqual(vm.quietTracksPress.state, .finished(.done(count: 1, skipped: 0)))
        XCTAssertTrue(vm.feed.tracks.isEmpty)

        vm.oldIdeasPress.begin()
        await settle(vm.oldIdeasPress) { if case .confirming = $0 { true } else { false } }
        XCTAssertEqual(vm.oldIdeasPress.state, .confirming(InboxBulkPlan(ids: [String(ideas[0])], count: 1)))
        vm.oldIdeasPress.confirm()
        await settle(vm.oldIdeasPress) { if case .finished = $0 { true } else { false } }
        XCTAssertEqual(vm.oldIdeasPress.state, .finished(.done(count: 1, skipped: 0)))
    }

    // MARK: - Root rows

    func testRowsUseNewsAndBatchRules() async throws {
        let now = clock.now()
        defaults.set(2, forKey: IdeaDailyBatch.sizeKey)
        try await pool.write { db in
            try InboxFolderFixtures.seed(db)
            try Self.track(now, "Release acme 2.0 checklist", daysAgo: 0.1, db: db)
            try Self.track(now, "Old vendor thread", daysAgo: 40, db: db)
            try db.execute(sql: "UPDATE tracks SET read_at = updated_at WHERE text = 'Old vendor thread'")
            _ = try Self.idea(now, "A shared glossary", daysAgo: 3, db: db)
            _ = try Self.idea(now, "Weekly digest", daysAgo: 2, db: db)
            _ = try Self.idea(now, "A third one", daysAgo: 1, db: db)
            _ = try Self.idea(now, "Long ago", daysAgo: 45, db: db)
        }
        let vm = makeVM()
        await vm.refresh()

        let rows = Dictionary(uniqueKeysWithValues: vm.folderList.rows.map { ($0.id, $0.content) })
        let tracks = try XCTUnwrap(rows["tracks"])
        let summary = vm.trackSummary
        XCTAssertEqual(summary.news.count, 1)
        XCTAssertEqual(tracks.preview, summary.rowPreview)
        XCTAssertEqual(tracks.meta, "1 quiet thread folded")
        XCTAssertEqual(tracks.pill, InboxRowPill(count: 1, tone: .news))
        XCTAssertTrue(tracks.isUnread)

        let ideas = try XCTUnwrap(rows["ideas"])
        XCTAssertEqual(vm.ideaBatch.remaining.map(\.title), ["A shared glossary", "Weekly digest"])
        XCTAssertEqual(ideas.preview, "Today’s 2 ideas to judge. Top one: “A shared glossary”.")
        XCTAssertEqual(ideas.meta, "2 in the backlog · 1 older than 30 days")
        XCTAssertEqual(ideas.pill, InboxRowPill(count: 2, tone: .batch))
        XCTAssertTrue(ideas.isUnread)
    }
}
