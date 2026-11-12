import Foundation
import GRDB
import XCTest
import WatchtowerTestSupport
@testable import WatchtowerCore

/// The entry each folder opens on (spec "Selection"): today's Morning brief
/// on the first read, the owner's last pick per folder (`inbox.entry.<id>`),
/// never a legacy list; a default pick writes no read mark until the owner
/// arrives (STRIP-02); midnight moves the brief to the new day; a pick of
/// a past day marks that day read.
@MainActor
final class InboxEntrySelectionTests: XCTestCase {
    private var pool: DatabasePool!
    private var path = ""
    private var suite = ""
    private var defaults: UserDefaults!
    private let clock = TestClock()

    override func setUp() async throws {
        (pool, path) = try TestDatabase.createPool()
        suite = "InboxEntrySelectionTests.\(UUID().uuidString)"
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

    private func makeVM() -> ActionStripViewModel {
        let clock = clock
        return ActionStripViewModel(
            dbPool: pool, cliRunner: FakeCLIRunner(), defaults: defaults, clock: { clock.now() },
            dayChangeSignals: [])
    }

    private func day(_ offset: Int) -> String {
        let date = Calendar.current.date(byAdding: .day, value: offset, to: clock.now()) ?? clock.now()
        return HomeFeedBuilder.dayString(date, calendar: .current)
    }

    private var today: String { day(0) }

    /// The folders, an owner (so the root lists today's brief) and an
    /// unread briefing for today.
    @discardableResult
    private func seed(briefing: Bool = true) async throws -> InboxFolderFixtures.Seed {
        let today = today
        return try await pool.write { db in
            let folders = try InboxFolderFixtures.seed(db)
            _ = try TestDatabase.insertSlackAccount(db, currentUserID: "1:U001")
            if briefing { try TestDatabase.insertBriefing(db, userID: "1:U001", date: today) }
            return folders
        }
    }

    private func readAt(_ date: String) async throws -> String? {
        try await pool.read { db in
            try String.fetchOne(
                db, sql: "SELECT read_at FROM briefings WHERE date = ? ORDER BY id DESC LIMIT 1", arguments: [date])
        }
    }

    /// An automation's artifact, in `folder` when one is given (else the root).
    nonisolated private static func artifact(
        _ db: Database, slug: String, created: String, folder: Int64? = nil
    ) throws -> Int64 {
        let automation = try TestDatabase.insertAutomation(db, slug: slug, name: slug.capitalized)
        let run = try TestDatabase.insertAutomationRun(db, automationID: automation)
        if let folder { try InboxFolderFixtures.route(db, automation: automation, folder: folder) }
        return try TestDatabase.insertAutomationOutput(
            db, automationID: automation, runID: run, title: slug.capitalized, createdAt: created)
    }

    // MARK: - The default entry

    func testFirstReadSelectsTodaysBrief() async throws {
        try await seed()
        let vm = makeVM()

        await vm.refresh()

        XCTAssertEqual(vm.entrySelection, "day:\(today)")
        XCTAssertEqual(vm.selection, .day(today))
        XCTAssertNil(vm.briefDate)
        XCTAssertEqual(vm.briefDay?.date, today)
    }

    func testRefreshAloneWritesNoReadMark() async throws {
        try await seed()
        let vm = makeVM()

        await vm.refresh()
        await vm.pollTick()

        XCTAssertEqual(vm.entrySelection, "day:\(today)")
        let mark = try await readAt(today)
        XCTAssertNil(mark, "a read writes nothing (STRIP-02)")
    }

    func testOwnerArrivalMarksTheShownBriefRead() async throws {
        let folders = try await seed()
        let vm = makeVM()
        await vm.refresh()
        let before = try XCTUnwrap(vm.folderMenu.snapshot.counts[folders.root])

        await vm.ownerArrived()
        await vm.refresh()

        let mark = try await readAt(today)
        XCTAssertNotNil(mark, "the brief on screen is opened")
        XCTAssertEqual(vm.folderMenu.snapshot.counts[folders.root], before - 1)
    }

    /// The arrival waits for the first read when none has landed yet.
    func testOwnerArrivalBeforeTheFirstReadWaitsForIt() async throws {
        try await seed()
        let vm = makeVM()

        await vm.ownerArrived()

        XCTAssertEqual(vm.entrySelection, "day:\(today)")
        let mark = try await readAt(today)
        XCTAssertNotNil(mark)
    }

    func testPollAfterArrivalWritesNothing() async throws {
        try await seed()
        let vm = makeVM()
        await vm.ownerArrived()
        // Today's brief is written again after the arrival (unread again).
        let today = today
        try await pool.write { db in
            try db.execute(sql: "UPDATE briefings SET read_at = NULL WHERE date = ?", arguments: [today])
        }

        await vm.pollTick()

        XCTAssertEqual(vm.briefDay?.isUnread, true, "the new version shows, unread")
        let mark = try await readAt(today)
        XCTAssertNil(mark, "a poll never marks anything read")

        // The owner cleared the selection: a poll never selects again.
        await vm.selectEntry(nil)
        await vm.pollTick()
        XCTAssertNil(vm.entrySelection)
        XCTAssertNil(vm.selection)
    }

    func testMidnightMovesTheBriefToToday() async throws {
        let calendar = Calendar.current
        let evening = calendar.date(bySettingHour: 23, minute: 30, second: 0, of: clock.now()) ?? clock.now()
        clock.set(evening)
        let yesterday = today
        let lateMessage = AutomationDates.format(evening.addingTimeInterval(-3600))
        try await seed()
        try await pool.write { db in
            let id = try TestDatabase.insertInboxItem(db)
            try db.execute(sql: "UPDATE inbox_items SET created_at = ? WHERE id = ?", arguments: [lateMessage, id])
        }
        let vm = makeVM()
        await vm.refresh()
        XCTAssertEqual(vm.entrySelection, "day:\(yesterday)")
        XCTAssertEqual(vm.folderMenu.snapshot.peopleWaitingToday, 1)

        clock.set(evening.addingTimeInterval(3600))
        let newToday = today
        XCTAssertNotEqual(newToday, yesterday)
        await vm.refresh()

        XCTAssertEqual(vm.entrySelection, "day:\(newToday)")
        XCTAssertEqual(vm.selection, .day(newToday))
        let mark = try await readAt(yesterday)
        XCTAssertNil(mark, "the rollover writes no read mark")
        XCTAssertEqual(vm.folderMenu.snapshot.peopleWaitingToday, 0, "yesterday's people no longer wait today")
    }

    // MARK: - Memory per folder

    private struct Picks {
        let folders: InboxFolderFixtures.Seed
        let owner: Int64
        let root: [Int64]
        let inOwner: [Int64]
    }

    /// Two artifacts in the root and two in an owner folder, the first of
    /// each the newest.
    private func seedPicks() async throws -> Picks {
        let folders = try await seed()
        return try await pool.write { db in
            let owner = try InboxFolderFixtures.folder(db, parent: folders.root, slug: "release", position: 1)
            let root = [
                try Self.artifact(db, slug: "weekly", created: "2026-11-06T09:30:00Z"),
                try Self.artifact(db, slug: "daily", created: "2026-11-06T09:00:00Z")
            ]
            let inOwner = [
                try Self.artifact(db, slug: "notes", created: "2026-11-06T09:30:00Z", folder: owner),
                try Self.artifact(db, slug: "digest", created: "2026-11-06T09:00:00Z", folder: owner)
            ]
            return Picks(folders: folders, owner: owner, root: root, inOwner: inOwner)
        }
    }

    func testRestoreLastEntryPerFolder() async throws {
        let picks = try await seedPicks()
        let vm = makeVM()
        await vm.refresh()
        await vm.selectEntry("artifact:\(picks.root[1])")
        vm.selectFolder(picks.owner)
        await vm.arrival?.value
        XCTAssertEqual(vm.entrySelection, "artifact:\(picks.inOwner[0])", "nothing picked there yet: the first")
        await vm.selectEntry("artifact:\(picks.inOwner[1])")

        vm.selectFolder(picks.folders.root)
        await vm.arrival?.value
        XCTAssertEqual(vm.entrySelection, "artifact:\(picks.root[1])")
        XCTAssertEqual(vm.selection, .output(picks.root[1]))
        vm.selectFolder(picks.owner)
        XCTAssertEqual(vm.entrySelection, "artifact:\(picks.inOwner[1])")
        XCTAssertEqual(defaults.string(forKey: ActionStripViewModel.entryKey(picks.owner)),
                       "artifact:\(picks.inOwner[1])")
        await vm.arrival?.value

        let next = makeVM()
        await next.refresh()
        XCTAssertEqual(next.folderMenu.selectedFolderID, picks.owner, "the folder opens again")
        XCTAssertEqual(next.entrySelection, "artifact:\(picks.inOwner[1])", "with its entry")
    }

    func testRestoreFallsBackWhenTheSavedEntryIsGone() async throws {
        let picks = try await seedPicks()
        let vm = makeVM()
        await vm.refresh()
        await vm.selectEntry("artifact:\(picks.root[0])")
        vm.selectFolder(picks.owner)
        await vm.arrival?.value
        await vm.selectEntry("artifact:\(picks.inOwner[1])")
        try await pool.write { db in
            try db.execute(sql: "DELETE FROM automation_outputs WHERE id IN (?, ?)",
                           arguments: [picks.root[0], picks.inOwner[1]])
        }
        await vm.refresh()

        vm.selectFolder(picks.folders.root)
        XCTAssertEqual(vm.entrySelection, "day:\(today)", "the root: today's brief")
        await vm.arrival?.value
        vm.selectFolder(picks.owner)
        await vm.arrival?.value
        XCTAssertEqual(vm.entrySelection, "artifact:\(picks.inOwner[0])", "an owner folder: its first entry")

        // The saved artifact's automation moved to the owner folder: the
        // root no longer lists it, so the root opens on today's brief.
        vm.selectFolder(picks.folders.root)
        await vm.arrival?.value
        await vm.selectEntry("artifact:\(picks.root[1])")
        try await pool.write { db in
            let automation = try XCTUnwrap(try Int64.fetchOne(
                db, sql: "SELECT automation_id FROM automation_outputs WHERE id = ?", arguments: [picks.root[1]]))
            try InboxFolderFixtures.route(db, automation: automation, folder: picks.owner)
        }
        await vm.refresh()
        vm.selectFolder(picks.owner)
        await vm.arrival?.value
        XCTAssertTrue(vm.folderEntries.contains { $0.id == "artifact:\(picks.root[1])" }, "it lists in its new folder")
        vm.selectFolder(picks.folders.root)
        await vm.arrival?.value
        XCTAssertEqual(vm.entrySelection, "day:\(today)", "moved away: today's brief")
    }

    func testRestoreNeverOpensALegacyList() async throws {
        let folders = try await seed()
        try await pool.write { db in _ = try TestDatabase.insertIdea(db, title: "A shared glossary") }
        let vm = makeVM()
        await vm.refresh()
        await vm.selectEntry(InboxFolderEntry.legacyIdeas.id)
        XCTAssertEqual(vm.legacyList, .ideas)
        XCTAssertEqual(defaults.string(forKey: ActionStripViewModel.entryKey(folders.root)), "ideas")

        vm.selectFolder(folders.root)
        await vm.arrival?.value

        XCTAssertEqual(vm.entrySelection, "day:\(today)")
        XCTAssertNil(vm.legacyList)
        let next = makeVM()
        await next.refresh()
        XCTAssertEqual(next.entrySelection, "day:\(today)")
        XCTAssertNil(next.legacyList)
    }

    func testEmptyFolderSelectsNothing() async throws {
        let folders = try await seed()
        let owner = try await pool.write { db in
            try InboxFolderFixtures.folder(db, parent: folders.root, slug: "release", position: 1)
        }
        let vm = makeVM()
        await vm.refresh()

        vm.selectFolder(owner)
        await vm.arrival?.value

        XCTAssertNil(vm.entrySelection)
        XCTAssertNil(vm.selection)
    }

    // MARK: - Routes

    private func outputReadAt(_ id: Int64) async throws -> String? {
        try await pool.read { db in
            try String.fetchOne(db, sql: "SELECT read_at FROM automation_outputs WHERE id = ?", arguments: [id])
        }
    }

    /// A route into the Inbox shows its own card: the owner's arrival
    /// (the view's onAppear) never marks the card shown before it, in any
    /// order the two can run in (STRIP-02).
    func testArrivalYieldsToARoute() async throws {
        let picks = try await seedPicks()
        let vm = makeVM()
        await vm.refresh()
        XCTAssertEqual(vm.entrySelection, "day:\(today)", "today's unread brief is on screen")

        // AppState begins the route before the Inbox shows; the arrival follows.
        vm.beginRoute()
        await vm.ownerArrived()
        await vm.open(folder: nil, select: .card(.output(picks.root[0])))
        XCTAssertEqual(vm.selection, .output(picks.root[0]))
        var brief = try await readAt(today)
        XCTAssertNil(brief, "the arrival yielded to the route")
        let first = try await outputReadAt(picks.root[0])
        XCTAssertNotNil(first, "the route's card is the one opened")

        // Before the first read: the arrival waits for it while a route
        // starts, whichever of the two runs first.
        try await pool.write { db in
            try db.execute(sql: "UPDATE automation_outputs SET read_at = NULL")
        }
        let fresh = makeVM()
        async let waiting: Void = fresh.ownerArrived()
        async let started: Void = fresh.open(folder: nil, select: .card(.output(picks.root[0])))
        _ = await (waiting, started)
        brief = try await readAt(today)
        XCTAssertNil(brief)
        let third = try await outputReadAt(picks.root[0])
        XCTAssertNotNil(third)
        let other = try await outputReadAt(picks.root[1])
        XCTAssertNil(other)
    }

    /// Routes can overlap: while a second announced route has not opened
    /// yet, the arrival still yields after the first one ends.
    func testArrivalYieldsWhileOverlappingRoutesRun() async throws {
        let picks = try await seedPicks()
        let vm = makeVM()
        await vm.refresh()

        vm.beginRoute()
        vm.beginRoute()
        await vm.open(folder: nil, select: .card(.output(picks.root[0])))
        try await pool.write { db in
            try db.execute(sql: "UPDATE automation_outputs SET read_at = NULL")
        }
        await vm.refresh()
        await vm.ownerArrived()
        let first = try await outputReadAt(picks.root[0])
        XCTAssertNil(first, "the second route is still on its way")

        await vm.open(folder: nil, select: .card(.output(picks.root[1])))
        let second = try await outputReadAt(picks.root[1])
        XCTAssertNotNil(second, "the second route's card is opened")
        let stillFirst = try await outputReadAt(picks.root[0])
        XCTAssertNil(stillFirst)

        // Both routes are over: the owner's next arrival marks its card.
        try await pool.write { db in
            try db.execute(sql: "UPDATE automation_outputs SET read_at = NULL")
        }
        await vm.refresh()
        await vm.ownerArrived()
        let after = try await outputReadAt(picks.root[1])
        XCTAssertNotNil(after, "no route left pending")
    }

    /// A route to a day the read does not hold opens today's brief, which
    /// stays unread: the owner clicked for another day.
    func testRouteToAnUnshownDayMarksNothing() async throws {
        try await seed()
        let vm = makeVM()
        await vm.refresh()

        await vm.open(folder: nil, select: .card(.day(day(-5))))

        XCTAssertEqual(vm.entrySelection, "day:\(today)")
        XCTAssertNil(vm.briefDate)
        let mark = try await readAt(today)
        XCTAssertNil(mark, "today's brief was not the day asked for")

        await vm.open(folder: nil, select: .card(.day(today)))
        let opened = try await readAt(today)
        XCTAssertNotNil(opened, "a route to today marks today")
    }

    func testOpenBriefHistoryWithoutABriefOpensNothing() async throws {
        // No owner and nothing written: the root lists no Morning brief.
        try await pool.write { db in _ = try InboxFolderFixtures.seed(db) }
        let vm = makeVM()
        await vm.refresh()
        XCTAssertFalse(vm.folderEntries.contains { $0.id == "day:\(today)" }, "no Morning brief listed")

        vm.openBriefHistory()

        XCTAssertNil(vm.entrySelection)
        XCTAssertFalse(vm.briefHistoryShown)
    }

    // MARK: - The brief's day

    func testShowBriefDayMarksThatDayRead() async throws {
        try await seed()
        let yesterday = day(-1)
        try await pool.write { db in
            try TestDatabase.insertBriefing(db, userID: "1:U001", date: yesterday)
        }
        let vm = makeVM()
        await vm.refresh()

        await vm.showBriefDay(yesterday)

        XCTAssertEqual(vm.entrySelection, "day:\(today)", "the root's one Morning brief entry")
        XCTAssertEqual(vm.briefDate, yesterday)
        XCTAssertEqual(vm.briefDay?.date, yesterday)
        XCTAssertEqual(vm.selection, .day(yesterday))
        let yesterdayMark = try await readAt(yesterday)
        XCTAssertNotNil(yesterdayMark, "the owner's pick opens that day")
        let todayMark = try await readAt(today)
        XCTAssertNil(todayMark, "today's brief stays unread")

        await vm.stepBrief(.newer)
        XCTAssertNil(vm.briefDate, "today")
        await vm.stepBrief(.older)
        XCTAssertEqual(vm.briefDate, yesterday)
        await vm.stepBrief(.older)
        XCTAssertEqual(vm.briefDate, yesterday, "nothing older: the day stays")

        vm.openBriefHistory()
        XCTAssertTrue(vm.briefHistoryShown)
        XCTAssertEqual(vm.briefDate, yesterday, "History opens over the day shown")
    }
}
