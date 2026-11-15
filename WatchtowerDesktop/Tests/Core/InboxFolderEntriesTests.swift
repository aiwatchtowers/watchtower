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
        // Sections: Waiting for me in Needs you, Idea finder in Running and
        // the artifact by its day (`.current`, as the view model reads it).
        let rows = vm.folderList.rows
        XCTAssertEqual(rows.first?.content.title, "Waiting for me")
        XCTAssertEqual(rows.first?.content.kind, .peopleWaiting)
        XCTAssertEqual(rows.first?.isArtifact, true, "its context menu is its automation's")
        let ideas = try XCTUnwrap(rows.first { $0.id == "ideas" })
        XCTAssertEqual(ideas.content.pill, InboxRowPill(count: 1, tone: .batch))
        XCTAssertEqual(ideas.menu.map(\.command), [.findIdeasInPastMessages])
        XCTAssertTrue(ideas.content.isUnread)
        let weekly = try XCTUnwrap(rows.first { $0.id == "artifact:\(ids.weekly)" })
        XCTAssertEqual(weekly.content.meta, "Your automation · run #\(ids.run)")
        XCTAssertTrue(weekly.content.isUnread)
        XCTAssertEqual(vm.folderList.sections.first?.title, "Needs you")
        XCTAssertEqual(vm.folderList.sections.last?.rows.last?.id, "ideas",
                       "Running: Idea finder, then artifacts older than today (none)")
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
                XCTAssertEqual(vm.folderList.rows.first?.content.title, "Messages", status)
                XCTAssertEqual(vm.folderList.rows.first?.content.kind, .peopleWaiting, status)
            }
            TestDatabase.cleanup(path: path)
            path = ""
        }
    }

    /// Turned off after a successful run (attention detection off flips only
    /// `enabled`): its stale card is not drawn and does not count, and the
    /// Messages entry does not stand in either. Stopped by the daemon (a
    /// `disabled_reason`) it is a failed run: the Messages entry stands in.
    func testWaitingForMeTurnedOffShowsAndCountsNothing() async throws {
        let pool = try pool()
        let ids = try await pool.write { db in
            let folders = try InboxFolderFixtures.seed(db)
            let waiting = try self.waitingForMe(db)
            try db.execute(sql: "UPDATE automations SET enabled = 0 WHERE id = ?", arguments: [waiting.automation])
            return (root: folders.root, automation: waiting.automation)
        }
        let vm = await read(pool, folder: ids.root)
        XCTAssertEqual(vm.folderEntries.map(\.id), [], "nothing is shown")
        XCTAssertEqual(vm.folderMenu.snapshot.counts[ids.root] ?? 0, 0, "nothing counts")
        XCTAssertTrue(vm.folderMenu.snapshot.waitingForMe.turnedOff)

        try await pool.write { db in
            try db.execute(sql: "UPDATE automations SET disabled_reason = 'run would not end' WHERE id = ?",
                           arguments: [ids.automation])
        }
        await vm.refresh()
        XCTAssertEqual(vm.folderEntries.map(\.id), ["messages"], "stopped: the Messages entry stands in")
    }

    /// The owner's off wins over the daemon's stop: attention detection
    /// turned off on a row the daemon already stopped (`SetBuiltinEnabled`
    /// leaves it unchanged, `disabled_reason` included) shows and counts
    /// nothing — neither the card nor the Messages stand-in, in the Inbox
    /// or in the badge.
    func testWaitingForMeStoppedThenTurnedOffShowsAndCountsNothing() async throws {
        let pool = try pool()
        let ids = try await pool.write { db in
            let folders = try InboxFolderFixtures.seed(db)
            let waiting = try self.waitingForMe(db, status: "failed")
            try db.execute(sql: "UPDATE automations SET enabled = 0, disabled_reason = 'run would not end' WHERE id = ?",
                           arguments: [waiting.automation])
            return (root: folders.root, automation: waiting.automation)
        }
        let vm = NeedsApprovalFixtures.viewModel(pool, suite: suite)
        vm.disabledFeatures = [InboxFolderQueries.waitingForMeFeatureID]
        await vm.refresh()
        vm.selectFolder(ids.root)
        XCTAssertEqual(vm.folderEntries.map(\.id), [], "turned off: nothing is shown")
        XCTAssertEqual(vm.folderMenu.snapshot.counts[ids.root] ?? 0, 0, "nothing counts")
        XCTAssertTrue(vm.folderMenu.snapshot.waitingForMe.turnedOff)
        let badge = try await pool.read { db in
            try ActionStripViewModel.badgeCount(
                db, nowUTC: "2026-11-06T10:00:00Z", disabledFeatures: [InboxFolderQueries.waitingForMeFeatureID])
        }
        XCTAssertEqual(badge, 0, "the badge counts no stand-in either")

        await vm.folderMenu.reload()
        XCTAssertTrue(vm.folderMenu.snapshot.waitingForMe.turnedOff, "the menu's own read keeps the switch")

        vm.disabledFeatures = []
        await vm.refresh()
        XCTAssertEqual(vm.folderEntries.map(\.id), ["messages"], "turned on again, the stop stands in")
    }

    /// An approved or executing proposal is not closed: Needs approval keeps
    /// it on its native card, after the open approvals (spec A, a stuck row's
    /// "Didn't finish" and Try again), and never counts it; an applied one
    /// leaves.
    func testNeedsApprovalKeepsApprovedAndExecutingRowsUncounted() async throws {
        let pool = try pool()
        let ids = try await pool.write { db in
            let folders = try InboxFolderFixtures.seed(db)
            let pending = try TestDatabase.insertAgentAction(db, status: "pending", createdAt: "2026-11-06T09:00:00Z")
            let approved = try TestDatabase.insertAgentAction(
                db, surface: "inbox", contextType: "automation_output", contextID: "5:0:0123456789abcdef",
                status: "approved", createdAt: "2026-11-06T09:01:00Z", decidedAt: "2026-11-06T09:02:00Z")
            let executing = try TestDatabase.insertAgentAction(
                db, status: "executing", createdAt: "2026-11-06T09:03:00Z", decidedAt: "2026-11-06T09:04:00Z")
            _ = try TestDatabase.insertAgentAction(db, status: "applied", createdAt: "2026-11-06T09:05:00Z",
                                                   decidedAt: "2026-11-06T09:06:00Z", appliedAt: "2026-11-06T09:06:00Z")
            return (folders: folders, pending: pending, approved: approved, executing: executing)
        }
        let vm = await read(pool, folder: ids.folders.approvals)
        let drawn = vm.folderEntries.compactMap { entry -> String? in
            guard case let .approval(item) = entry, item.recipe == nil else { return nil }
            return item.key
        }
        XCTAssertEqual(drawn.first, "action:\(ids.pending)", "the open approval first")
        XCTAssertEqual(Set(drawn), ["action:\(ids.pending)", "action:\(ids.approved)", "action:\(ids.executing)"])
        XCTAssertEqual(vm.folderMenu.snapshot.counts[ids.folders.approvals], 1, "only the open approval counts")
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
        XCTAssertNil(vm.folderList.rows.first?.content.pill, "nothing unread")
        await vm.selectEntry("tracks")
        XCTAssertEqual(vm.entrySelection, "tracks")
        XCTAssertNil(vm.legacyList, "Track my threads shows its own pane (phase 3)")
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

    /// Idea finder's entry shows its own pane (phase 3), not today's list;
    /// a card route still opens the list, and back returns to the entry.
    func testIdeaFinderEntryShowsItsPaneAndCardRouteOpensList() async throws {
        let pool = try pool()
        let idea = try await pool.write { db in
            try InboxFolderFixtures.seed(db)
            return try TestDatabase.insertIdea(db)
        }
        let vm = await read(pool)
        await vm.selectEntry("ideas")
        XCTAssertNil(vm.legacyList)
        await vm.open(folder: nil, select: .card(.idea(Int(idea))))
        XCTAssertEqual(vm.legacyList, .ideas)
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

    /// The selected artifact leaves and Idea finder is next: it is selected
    /// as a click selects it, on its own pane (phase 3).
    func testSelectionMovingToIdeaFinderSelectsItsPane() async throws {
        let inbox = try await rootWithArtifact { try TestDatabase.insertIdea($0, updatedAt: "2026-11-06T08:00:00Z") }
        XCTAssertEqual(inbox.vm.folderEntries.map(\.id), ["artifact:\(inbox.card)", "ideas"])

        await inbox.vm.markOutputDone(inbox.card)

        XCTAssertEqual(inbox.vm.entrySelection, "ideas")
        XCTAssertNil(inbox.vm.legacyList, "Idea finder's own pane, no legacy list")
    }

    /// The selected artifact leaves and a day is next: the day is selected
    /// as a click selects it, but no read mark is written — only the
    /// owner's own gesture marks a card read (STRIP-02).
    func testSelectionMovingToADaySelectsItAndLeavesItUnread() async throws {
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
        XCTAssertNil(readAt, "moving the selection writes no read mark")
    }

    /// The selected artifact is closed elsewhere and a 30 s poll sees it:
    /// the next artifact is selected and shown, and the poll writes nothing
    /// — no read mark on the card it moved to (STRIP-02).
    func testSelectionMovingOnAPollWritesNothing() async throws {
        let inbox = try await rootWithArtifact { db in
            let other = try TestDatabase.insertAutomation(db, slug: "daily", name: "Daily notes")
            let run = try TestDatabase.insertAutomationRun(db, automationID: other)
            try TestDatabase.insertAutomationOutput(
                db, automationID: other, runID: run, title: "Daily notes", createdAt: "2026-11-06T09:00:00Z")
        }
        let next = try XCTUnwrap(inbox.vm.folderEntries.map(\.id).first { $0 != "artifact:\(inbox.card)" })
        try await inbox.pool.write { db in
            try db.execute(
                sql: "UPDATE automation_outputs SET done_at = '2026-11-06T10:00:00Z' WHERE id = ?",
                arguments: [inbox.card])
        }
        let marks = {
            try await inbox.pool.read { db in
                let rows = try Row.fetchAll(
                    db, sql: "SELECT id, read_at, done_at, dismissed_at FROM automation_outputs ORDER BY id")
                return rows.map(\.description)
            }
        }
        let before = try await marks()

        await inbox.vm.pollTick()

        XCTAssertEqual(inbox.vm.entrySelection, next)
        let nextID = try XCTUnwrap(Int64(next.dropFirst("artifact:".count)))
        XCTAssertEqual(inbox.vm.selection, .output(nextID), "the pane follows")
        let after = try await marks()
        XCTAssertEqual(after, before, "a poll never marks anything read")
    }

    /// One brief row: the root lists today's Morning brief only; an unread
    /// past day is counted on the Earlier line instead.
    func testRootListsOnlyTodaysBrief() async throws {
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
        XCTAssertEqual(vm.folderEntries.map(\.id), ["day:\(today)"], "yesterday's unread brief is not a row")
        XCTAssertEqual(vm.folderList.sections.map(\.title), ["Today"])
        XCTAssertEqual(vm.folderList.earlierLine, InboxEarlierLine(pastThisMonth: 1, notOpened: 1))
    }

    /// A route (Home, a notification) opens its list for this session
    /// only: the remembered folder is never a route's.
    func testRouteNeverRemembersItsFolder() async throws {
        let pool = try pool()
        try await pool.write { db in
            try InboxFolderFixtures.seed(db)
            try TestDatabase.insertTrack(db, text: "Release acme 2.0 checklist")
        }
        let vm = await read(pool)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))

        await vm.open(folder: nil, select: .legacy(.tracks))

        XCTAssertNil(vm.legacyList, "Track my threads' own pane")
        XCTAssertEqual(vm.entrySelection, "tracks")
        XCTAssertNil(defaults.object(forKey: ActionStripViewModel.folderKey), "not written into inbox.folder")
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
