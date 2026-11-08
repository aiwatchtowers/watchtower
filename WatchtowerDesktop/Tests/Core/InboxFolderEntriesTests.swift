import GRDB
import XCTest
import WatchtowerTestSupport
@testable import WatchtowerCore

/// A folder's entries over the Inbox's one read (plan Task 12): the root's
/// composition (Waiting for me pinned, legacy entries by their own time),
/// an owner folder of two automations, the Messages stand-in's three
/// conditions, and a failed read keeping what was on screen.
@MainActor
final class InboxFolderEntriesTests: XCTestCase {
    private var path = ""
    private let suite = "InboxFolderEntriesTests.\(UUID().uuidString)"

    override func tearDown() {
        if !path.isEmpty { TestDatabase.cleanup(path: path) }
        UserDefaults.standard.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func pool() throws -> DatabasePool {
        let (pool, path) = try TestDatabase.createPool()
        self.path = path
        return pool
    }

    private func read(_ pool: DatabasePool, folder: Int64? = nil) async -> ActionStripViewModel {
        let vm = NeedsApprovalFixtures.viewModel(pool, suite: suite)
        await vm.refresh()
        if let folder { vm.selectFolder(folder) }
        return vm
    }

    /// Waiting for me with one row waiting on the owner (an open message).
    nonisolated private func waitingForMe(_ db: Database, status: String = "succeeded") throws -> (automation: Int64, card: Int64) {
        let item = try TestDatabase.insertInboxItem(db)
        let automation = try NeedsApprovalFixtures.builtin(db, id: "waiting-for-me", name: "Waiting for me")
        let run = try NeedsApprovalFixtures.run(db, automation, status: status)
        let card = try NeedsApprovalFixtures.card(
            db, automation, run: run, key: "waiting", written: "2026-11-06T09:00:00Z", title: "Waiting for me",
            blocks: InboxFolderFixtures.listDocument([("inbox_item", item)]))
        return (automation, card)
    }

    func testRootPinsWaitingForMeThenOrdersByTime() async throws {
        let pool = try pool()
        let ids = try await pool.write { db in
            let folders = try InboxFolderFixtures.seed(db)
            let waiting = try self.waitingForMe(db)
            let owner = try TestDatabase.insertAutomation(db, slug: "weekly", name: "Weekly mail roundup")
            let run = try TestDatabase.insertAutomationRun(db, automationID: owner)
            let weekly = try TestDatabase.insertAutomationOutput(
                db, automationID: owner, runID: run, title: "Weekly mail roundup", createdAt: "2026-11-06T09:30:00Z")
            try TestDatabase.insertIdea(db, updatedAt: "2026-11-06T09:45:00Z")
            return (root: folders.root, waiting: waiting.card, weekly: weekly, run: run)
        }
        let vm = await read(pool, folder: ids.root)

        XCTAssertEqual(vm.folderEntries.map(\.id), ["artifact:\(ids.waiting)", "ideas", "artifact:\(ids.weekly)"])
        let rows = vm.folderList.rows
        XCTAssertEqual(rows.map(\.title), ["Waiting for me", "Idea finder", "Weekly mail roundup"])
        XCTAssertEqual(rows[0].summary, "1 waiting")
        XCTAssertEqual(rows[1].summary, "1 to judge")
        XCTAssertEqual(rows[1].menu.map(\.command), [.findIdeasInPastMessages])
        XCTAssertEqual(rows[2].detail, "run #\(ids.run) · 30 min ago")
        XCTAssertTrue(rows.allSatisfy(\.unread))
        XCTAssertFalse(vm.folderEntries.contains(.legacyMessages), "Waiting for me ran: no Messages entry")
    }

    /// Waiting for me with nothing waiting is not pinned: it takes its place by time.
    func testWaitingForMeWithoutWaitingRowsIsNotPinned() async throws {
        let pool = try pool()
        let ids = try await pool.write { db in
            let folders = try InboxFolderFixtures.seed(db)
            let automation = try NeedsApprovalFixtures.builtin(db, id: "waiting-for-me", name: "Waiting for me")
            let run = try NeedsApprovalFixtures.run(db, automation)
            let card = try NeedsApprovalFixtures.card(
                db, automation, run: run, key: "waiting", written: "2026-11-06T08:00:00Z",
                blocks: #"{"v":1,"blocks":[{"type":"list","rows":[],"empty":"Nobody is waiting on you"}]}"#)
            try TestDatabase.insertIdea(db, updatedAt: "2026-11-06T09:45:00Z")
            return (root: folders.root, card: card)
        }
        let vm = await read(pool, folder: ids.root)
        XCTAssertEqual(vm.folderEntries.map(\.id), ["ideas", "artifact:\(ids.card)"])
    }

    func testOwnerFolderListsItsTwoAutomationsNewestFirst() async throws {
        let pool = try pool()
        let ids = try await pool.write { db in
            let folders = try InboxFolderFixtures.seed(db)
            let release = try InboxFolderFixtures.folder(db, parent: folders.root, slug: "release", position: 0)
            var cards: [Int64] = []
            for (slug, at) in [("notes", "2026-11-06T08:00:00Z"), ("checklist", "2026-11-06T09:00:00Z")] {
                let automation = try TestDatabase.insertAutomation(db, slug: slug, name: slug)
                try InboxFolderFixtures.route(db, automation: automation, folder: release)
                let run = try TestDatabase.insertAutomationRun(db, automationID: automation)
                cards.append(try TestDatabase.insertAutomationOutput(
                    db, automationID: automation, runID: run, title: slug, createdAt: at))
            }
            try TestDatabase.insertIdea(db)
            return (root: folders.root, release: release, cards: cards)
        }
        let vm = await read(pool, folder: ids.release)

        XCTAssertEqual(vm.folderEntries.map(\.id), ["artifact:\(ids.cards[1])", "artifact:\(ids.cards[0])"])
        XCTAssertEqual(vm.folderList.folderTitle, "Release")
        vm.selectFolder(ids.root)
        XCTAssertEqual(vm.folderEntries.map(\.id), ["ideas"], "the routed artifacts are not in the root")
    }

    /// The Messages entry stands in before Waiting for me's first run and
    /// after a failed one — and then its stale card is not drawn; once it
    /// succeeded, Waiting for me is drawn and the Messages entry goes.
    func testMessagesStandInThreeConditions() async throws {
        for status in ["none", "failed", "succeeded"] {
            let pool = try pool()
            let ids = try await pool.write { db -> (root: Int64, card: Int64?) in
                let folders = try InboxFolderFixtures.seed(db)
                guard status != "none" else {
                    _ = try TestDatabase.insertInboxItem(db)
                    return (folders.root, nil)
                }
                return (folders.root, try self.waitingForMe(db, status: status).card)
            }
            let vm = await read(pool, folder: ids.root)
            switch status {
            case "succeeded":
                XCTAssertEqual(vm.folderEntries.map(\.id), ["artifact:\(ids.card ?? 0)"], status)
            default:
                XCTAssertEqual(vm.folderEntries.map(\.id), ["messages"], status)
                XCTAssertEqual(vm.folderList.rows.first?.summary, "1 waiting", status)
            }
            TestDatabase.cleanup(path: path)
            path = ""
        }
    }

    /// Every track stopped: Track my threads stays, so its Stopped fold and
    /// Restore stay reachable.
    func testTrackMyThreadsStaysWhileTracksAreStopped() async throws {
        let pool = try pool()
        let root = try await pool.write { db in
            let folders = try InboxFolderFixtures.seed(db)
            let track = try TestDatabase.insertTrack(db, text: "Release acme 2.0 checklist")
            try db.execute(sql: "UPDATE tracks SET dismissed_at = '2026-11-06T09:00:00Z' WHERE id = ?",
                           arguments: [track])
            return folders.root
        }
        let vm = await read(pool, folder: root)
        XCTAssertEqual(vm.folderEntries.map(\.id), ["tracks"])
        XCTAssertEqual(vm.folderList.rows.first?.summary, "", "nothing unread")
        await vm.selectEntry("tracks")
        XCTAssertEqual(vm.legacyList, .tracks)
    }

    /// No ideas yet: Idea finder stays while its built-in exists, so New
    /// idea and Find Ideas in Past Messages… stay reachable; without the
    /// built-in and without ideas it is left out.
    func testIdeaFinderStaysWhileItsBuiltinExists() async throws {
        let pool = try pool()
        let root = try await pool.write { db in try InboxFolderFixtures.seed(db).root }
        let without = await read(pool, folder: root)
        XCTAssertEqual(without.folderEntries.map(\.id), [], "no built-in, no ideas: nothing to show")

        try await pool.write { try NeedsApprovalFixtures.builtin($0, id: "idea-finder", name: "Idea finder") }
        let with = await read(pool, folder: root)
        XCTAssertEqual(with.folderEntries.map(\.id), ["ideas"])
        XCTAssertEqual(with.folderList.rows.first?.menu.map(\.command), [.findIdeasInPastMessages])
    }

    /// Opening a legacy list entry opens today's list for it; back returns.
    func testLegacyListEntryOpensTodaysList() async throws {
        let pool = try pool()
        try await pool.write { db in
            try InboxFolderFixtures.seed(db)
            try TestDatabase.insertIdea(db)
        }
        let vm = await read(pool)
        await vm.selectEntry("ideas")
        XCTAssertEqual(vm.legacyList, .ideas)
        XCTAssertEqual(vm.filter, .ideas)
        XCTAssertFalse(vm.sections.isEmpty, "the Ideas list itself")
        vm.closeLegacy()
        XCTAssertNil(vm.legacyList)
        XCTAssertEqual(vm.entrySelection, "ideas", "the entry stays selected in its folder")
    }

    /// An artifact in the root, with `extra` below it.
    private func rootWithArtifact(_ extra: @escaping (Database) throws -> Void) async throws
        -> (vm: ActionStripViewModel, pool: DatabasePool, card: Int64) {
        let pool = try pool()
        let ids = try await pool.write { db in
            let folders = try InboxFolderFixtures.seed(db)
            let owner = try TestDatabase.insertAutomation(db, slug: "weekly", name: "Weekly mail roundup")
            let run = try TestDatabase.insertAutomationRun(db, automationID: owner)
            let card = try TestDatabase.insertAutomationOutput(
                db, automationID: owner, runID: run, title: "Weekly mail roundup", createdAt: "2026-11-06T09:59:00Z")
            try extra(db)
            return (root: folders.root, card: card)
        }
        let vm = await read(pool, folder: ids.root)
        await vm.selectEntry("artifact:\(ids.card)")
        return (vm, pool, ids.card)
    }

    /// The selected artifact leaves and Idea finder is next: its list opens
    /// as a click on it opens it.
    func testSelectionMovingToALegacyEntryOpensItsList() async throws {
        let inbox = try await rootWithArtifact { try TestDatabase.insertIdea($0, updatedAt: "2026-11-06T08:00:00Z") }
        XCTAssertEqual(inbox.vm.folderEntries.map(\.id), ["artifact:\(inbox.card)", "ideas"])

        await inbox.vm.markOutputDone(inbox.card)

        XCTAssertEqual(inbox.vm.entrySelection, "ideas")
        XCTAssertEqual(inbox.vm.legacyList, .ideas, "the pane shows the Ideas list, not \"Select a card\"")
        XCTAssertEqual(inbox.vm.filter, .ideas)
    }

    /// The selected artifact leaves and a day is next: the day is selected
    /// as a click selects it, its briefing's read mark written.
    func testSelectionMovingToADaySelectsItAndMarksItRead() async throws {
        let today = HomeFeedBuilder.dayString(NeedsApprovalFixtures.now, calendar: .current)
        let inbox = try await rootWithArtifact { db in
            _ = try TestDatabase.insertSlackAccount(db, currentUserID: "1:U001")
            try TestDatabase.insertBriefing(db, userID: "1:U001", date: today)
        }
        XCTAssertEqual(inbox.vm.folderEntries.map(\.id).sorted(), ["artifact:\(inbox.card)", "day:\(today)"])

        await inbox.vm.markOutputDone(inbox.card)

        XCTAssertEqual(inbox.vm.entrySelection, "day:\(today)")
        XCTAssertEqual(inbox.vm.selection, .day(today))
        let readAt = try await inbox.pool.read { try String.fetchOne($0, sql: "SELECT read_at FROM briefings") }
        XCTAssertNotNil(readAt, "the day's read mark is written, as a click writes it")
    }

    /// Yesterday's unread brief, opened: its read mark is written, and it
    /// stays listed while it is selected — it leaves once the selection moves.
    func testSelectedDayStaysListedOnceRead() async throws {
        let today = HomeFeedBuilder.dayString(NeedsApprovalFixtures.now, calendar: .current)
        let yesterday = HomeFeedBuilder.dayString(
            NeedsApprovalFixtures.now.addingTimeInterval(-86400), calendar: .current)
        let pool = try pool()
        let root = try await pool.write { db in
            let folders = try InboxFolderFixtures.seed(db)
            _ = try TestDatabase.insertSlackAccount(db, currentUserID: "1:U001")
            try TestDatabase.insertBriefing(db, userID: "1:U001", date: today, readAt: "2026-11-06T08:00:00Z")
            try TestDatabase.insertBriefing(db, userID: "1:U001", date: yesterday)
            return folders.root
        }
        let vm = await read(pool, folder: root)
        XCTAssertTrue(vm.folderEntries.contains { $0.id == "day:\(yesterday)" }, "unread: listed")

        await vm.selectEntry("day:\(yesterday)")

        let unread = try await pool.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM briefings WHERE read_at IS NULL")
        }
        XCTAssertEqual(unread, 0, "the read mark is written")
        XCTAssertEqual(vm.entrySelection, "day:\(yesterday)", "the brief stays open while it is read")
        XCTAssertTrue(vm.folderEntries.contains { $0.id == "day:\(yesterday)" })

        await vm.selectEntry("day:\(today)")
        XCTAssertFalse(vm.folderEntries.contains { $0.id == "day:\(yesterday)" }, "read and not selected: gone")
    }

    /// A route (Home, a notification) opens its list for this session
    /// only: the remembered filter is never a route's.
    func testRouteNeverRemembersItsFilter() async throws {
        let pool = try pool()
        try await pool.write { db in
            try InboxFolderFixtures.seed(db)
            try TestDatabase.insertTrack(db, text: "Release acme 2.0 checklist")
        }
        let vm = await read(pool)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))

        await vm.open(.tracks, select: nil)

        XCTAssertEqual(vm.legacyList, .tracks)
        XCTAssertEqual(vm.filter, .tracks)
        XCTAssertNil(defaults.string(forKey: ActionStripViewModel.filterKey), "not written into inbox.filter")
    }

    /// The folder read fails: the previous tree and entries stay, with
    /// today's strip-wide error line.
    func testFolderReadFailureKeepsPreviousTree() async throws {
        let pool = try pool()
        let ids = try await pool.write { db in
            let folders = try InboxFolderFixtures.seed(db)
            let release = try InboxFolderFixtures.folder(db, parent: folders.root, slug: "release", position: 0)
            let automation = try TestDatabase.insertAutomation(db, slug: "notes", name: "Notes")
            try InboxFolderFixtures.route(db, automation: automation, folder: release)
            let run = try TestDatabase.insertAutomationRun(db, automationID: automation)
            let card = try TestDatabase.insertAutomationOutput(db, automationID: automation, runID: run)
            return (release: release, card: card)
        }
        let vm = await read(pool, folder: ids.release)
        let tree = vm.folderMenu.tree
        XCTAssertEqual(vm.folderEntries.map(\.id), ["artifact:\(ids.card)"])

        try await pool.write { db in
            try db.execute(sql: "DROP VIEW inbox_artifact_folders")
            try db.execute(sql: "CREATE VIEW inbox_artifact_folders AS SELECT 1 AS unrelated")
        }
        await vm.refresh()

        XCTAssertNotNil(vm.lastError, "today's strip error line")
        XCTAssertNotNil(vm.folderMenu.readError)
        XCTAssertEqual(vm.folderMenu.tree, tree, "the previous tree stays")
        XCTAssertEqual(vm.folderEntries.map(\.id), ["artifact:\(ids.card)"], "the previous list stays")
    }
}
