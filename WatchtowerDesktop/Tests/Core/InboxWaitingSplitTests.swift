import GRDB
import XCTest
import WatchtowerTestSupport
@testable import WatchtowerCore

/// People and mail split in the Inbox list (plan Task 13): the people-only
/// waiting term (badge, Waiting for me's pill and preview) on the artifact
/// and the Messages stand-in paths, and the Mail waiting row — after its
/// first run only, right after Waiting for me, never counted, hidden when
/// turned off.
@MainActor
final class InboxWaitingSplitTests: XCTestCase {
    private var path = ""
    private let suite = "InboxWaitingSplitTests.\(UUID().uuidString)"
    private let nowUTC = "2026-11-06T10:00:00Z"

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

    private func read(_ pool: DatabasePool, folder: Int64) async -> ActionStripViewModel {
        let vm = NeedsApprovalFixtures.viewModel(pool, suite: suite)
        await vm.refresh()
        vm.selectFolder(folder)
        return vm
    }

    /// `seconds` before the fixtures' now (2026-11-06T10:00:00Z).
    nonisolated private static func ago(_ seconds: TimeInterval) -> String {
        AutomationDates.format(NeedsApprovalFixtures.now.addingTimeInterval(-seconds))
    }

    private static let minute: TimeInterval = 60
    private static let yesterday: TimeInterval = 30 * 3600

    @discardableResult
    nonisolated private func item(
        _ db: Database, _ n: Int, trigger: String, created: String, sender: String = "U002"
    ) throws -> Int64 {
        let id = try TestDatabase.insertInboxItem(
            db, messageTS: "1700000\(String(format: "%04d", n)).000100", senderUserID: sender,
            triggerType: trigger, snippet: "item \(n)")
        try db.execute(sql: "UPDATE inbox_items SET created_at = ? WHERE id = ?", arguments: [created, id])
        return id
    }

    /// A Slack DM today, a mail today and a mention yesterday.
    nonisolated private func seedSplit(_ db: Database) throws -> (dm: Int64, mail: Int64, mention: Int64) {
        (try item(db, 1, trigger: "dm", created: Self.ago(Self.minute)),
         try item(db, 2, trigger: "email_received", created: Self.ago(2 * Self.minute), sender: "news@example.com"),
         try item(db, 3, trigger: "mention", created: Self.ago(Self.yesterday)))
    }

    /// Waiting for me after a successful run, listing `items`.
    @discardableResult
    nonisolated private func waitingForMe(_ db: Database, items: [Int64]) throws -> (automation: Int64, card: Int64) {
        let automation = try NeedsApprovalFixtures.builtin(db, id: "waiting-for-me", name: "Waiting for me")
        let run = try NeedsApprovalFixtures.run(db, automation)
        let card = try NeedsApprovalFixtures.card(
            db, automation, run: run, key: "waiting", written: Self.ago(5 * Self.minute), title: "Waiting for me",
            blocks: InboxFolderFixtures.listDocument(items.map { ("inbox_item", $0) }))
        return (automation, card)
    }

    /// Mail waiting's built-in row, with no run yet.
    nonisolated private func mailBuiltin(_ db: Database) throws -> Int64 {
        try NeedsApprovalFixtures.builtin(db, id: "mail-waiting", name: "Mail waiting")
    }

    /// Mail waiting's living card listing `senders` (`mail_sender` refs).
    @discardableResult
    nonisolated private func mailCard(_ db: Database, _ automation: Int64, senders: [String]) throws -> Int64 {
        let run = try NeedsApprovalFixtures.run(db, automation)
        let rows = senders.map { #"{"title":"\#($0)","ref":{"kind":"mail_sender","id":"\#($0)"}}"# }
        return try NeedsApprovalFixtures.card(
            db, automation, run: run, key: "mail", written: Self.ago(4 * Self.minute), title: "Mail waiting",
            blocks: #"{"v":1,"blocks":[{"type":"list","rows":[\#(rows.joined(separator: ","))]}]}"#)
    }

    private func badge(_ pool: DatabasePool, disabled: Set<String> = []) async throws -> Int {
        let utc = try InboxTodayFixture.calendar("UTC")
        return try await pool.read { db in
            try ActionStripViewModel.badgeCount(db, nowUTC: self.nowUTC, disabledFeatures: disabled, calendar: utc)
        }
    }

    // MARK: - People only

    func testBadgeCountsPeopleTodayNotMail() async throws {
        let pool = try pool()
        let ids = try await pool.write { db in
            _ = try InboxFolderFixtures.seed(db)
            return try self.seedSplit(db)
        }
        let standIn = try await badge(pool)
        XCTAssertEqual(standIn, 1, "the Messages stand-in: the DM today; mail and yesterday's mention never count")

        try await pool.write { db in try self.waitingForMe(db, items: [ids.dm, ids.mention]) }
        let artifact = try await badge(pool)
        XCTAssertEqual(artifact, 1, "Waiting for me's artifact: the same people term")
    }

    func testWaitingForMePillCountsPeopleToday() async throws {
        // The stand-in path, then the artifact path.
        for withArtifact in [false, true] {
            let pool = try pool()
            let root = try await pool.write { db -> Int64 in
                let folders = try InboxFolderFixtures.seed(db)
                let ids = try self.seedSplit(db)
                let other = try self.item(db, 4, trigger: "linear_assigned", created: Self.ago(3 * Self.minute))
                if withArtifact { try self.waitingForMe(db, items: [ids.dm, other, ids.mention]) }
                return folders.root
            }
            let vm = await read(pool, folder: root)
            let row = try XCTUnwrap(vm.folderList.rows.first { $0.content.kind == .peopleWaiting }, "\(withArtifact)")
            XCTAssertEqual(row.content.pill, InboxRowPill(count: 2, tone: .needsYou), "people today: the DM and the Linear item")
            XCTAssertTrue(row.content.preview.hasSuffix(" · and 1 more today"),
                          "\(withArtifact): the mail today is not one more: \(row.content.preview)")
            XCTAssertTrue(row.content.preview.contains("item 1"), "the newest person, not the mail")
            XCTAssertEqual(vm.folderMenu.snapshot.peopleWaitingToday, 2)
            TestDatabase.cleanup(path: path)
            path = ""
        }
    }

    /// The older count is the uncapped people count (`PeopleWaitingCounts
    /// .older`), not the feed's page, which mail can fill.
    func testWaitingForMeOlderCountIgnoresTheMailCappedFeed() async throws {
        let pool = try pool()
        let root = try await pool.write { db -> Int64 in
            let folders = try InboxFolderFixtures.seed(db)
            for n in 0..<250 {
                try self.item(db, 100 + n, trigger: "email_received", created: Self.ago(Self.minute + Double(n)),
                              sender: "news@example.com")
            }
            for n in 0..<3 {
                try self.item(db, 10 + n, trigger: "mention", created: Self.ago(8 * 24 * 3600 + Double(n)))
            }
            return folders.root
        }
        let vm = await read(pool, folder: root)
        let row = try XCTUnwrap(vm.folderList.rows.first { $0.content.kind == .peopleWaiting })
        XCTAssertEqual(row.content.meta, "3 older")
        XCTAssertEqual(vm.folderMenu.snapshot.peopleWaiting.older, 3)
    }

    // MARK: - Mail waiting

    func testMailWaitingRowAfterFirstRunOnly() async throws {
        let pool = try pool()
        let ids = try await pool.write { db in
            let folders = try InboxFolderFixtures.seed(db)
            _ = try self.seedSplit(db)
            _ = try self.item(db, 5, trigger: "email_received", created: Self.ago(Self.yesterday), sender: "news@example.com")
            return (root: folders.root, mail: try self.mailBuiltin(db))
        }
        var vm = await read(pool, folder: ids.root)
        XCTAssertFalse(vm.folderList.rows.contains { $0.content.kind == .mailWaiting }, "no run: no row, no stand-in")

        try await pool.write { db in _ = try NeedsApprovalFixtures.run(db, ids.mail, status: "failed") }
        vm = await read(pool, folder: ids.root)
        XCTAssertFalse(vm.folderList.rows.contains { $0.content.kind == .mailWaiting }, "a failed first run writes no card")

        let card = try await pool.write { db in try self.mailCard(db, ids.mail, senders: ["news@example.com"]) }
        vm = await read(pool, folder: ids.root)
        let row = try XCTUnwrap(vm.folderList.rows.first { $0.id == "artifact:\(card)" })
        XCTAssertEqual(row.content.kind, .mailWaiting)
        XCTAssertEqual(row.content.title, "Mail waiting")
        XCTAssertEqual(row.content.preview, "1 new today. Most of it comes from 1 sender: clear a sender in one press.")
        XCTAssertEqual(row.content.meta, "2 open · 100% from 1 sender")
        XCTAssertEqual(row.content.pill, InboxRowPill(count: 1, tone: .batch), "mail from today, neutral")
        XCTAssertFalse(row.content.isUnread)
        XCTAssertTrue(row.isArtifact)
        XCTAssertEqual(vm.folderMenu.snapshot.mailWaiting, MailWaitingState(automationID: ids.mail, turnedOff: false))
    }

    func testMailWaitingRowSitsRightAfterWaitingForMe() async throws {
        let pool = try pool()
        let ids = try await pool.write { db in
            let folders = try InboxFolderFixtures.seed(db)
            let split = try self.seedSplit(db)
            let mail = try self.mailCard(db, try self.mailBuiltin(db), senders: ["news@example.com"])
            let waiting = try self.waitingForMe(db, items: [split.dm])
            return (root: folders.root, mail: mail, waiting: waiting.card)
        }
        let vm = await read(pool, folder: ids.root)
        let needsYou = try XCTUnwrap(vm.folderList.sections.first)
        XCTAssertEqual(needsYou.title, "Needs you")
        XCTAssertEqual(needsYou.rows.map(\.id), ["artifact:\(ids.waiting)", "artifact:\(ids.mail)"])

        // The pure rule: after Waiting for me or its stand-in, before the
        // thread briefs and the approvals.
        let now = NeedsApprovalFixtures.now
        func card(_ id: Int64, _ automation: Int64) -> InboxFolderEntry {
            .artifact(AutomationOutputCard(
                id: id, automationID: automation, automationName: "A\(id)", runID: 1, title: "A\(id)", body: "",
                priority: "", createdAt: now, changedAt: now))
        }
        let brief = InboxFolderEntry.brief(AgentAction(row: Row([
            "id": 1, "tool": "brief_context", "status": "applied", "applied_at": Self.ago(Self.minute)
        ])))
        for (waiting, expected) in [(card(7, 3), "artifact:7"), (.legacyMessages, "messages")] {
            let sections = InboxRootSections.build(
                entries: [brief, card(8, 4), waiting], folder: .root, waitingForMeAutomationID: 3,
                mailWaitingAutomationID: 4, now: now, calendar: try InboxTodayFixture.calendar("UTC"))
            XCTAssertEqual(sections.first?.0, .needsYou)
            XCTAssertEqual(sections.first?.1.map(\.id), [expected, "artifact:8", "brief:1"])
        }
    }

    func testMailWaitingNeverCounts() async throws {
        let pool = try pool()
        let ids = try await pool.write { db in
            let folders = try InboxFolderFixtures.seed(db)
            _ = try self.seedSplit(db)
            return (root: folders.root, mail: try self.mailBuiltin(db))
        }
        let badgeBefore = try await badge(pool)
        let rootBefore = await read(pool, folder: ids.root).folderMenu.snapshot.counts[ids.root] ?? 0

        // Unread, with rows that wait (open mail from its sender), then an
        // unread card with no rows.
        for senders in [["news@example.com"], []] {
            try await pool.write { db in
                try db.execute(sql: "DELETE FROM automation_outputs WHERE automation_id = ?", arguments: [ids.mail])
                try self.mailCard(db, ids.mail, senders: senders)
            }
            let vm = await read(pool, folder: ids.root)
            XCTAssertTrue(vm.folderList.rows.contains { $0.content.kind == .mailWaiting }, "\(senders)")
            let badgeNow = try await badge(pool)
            XCTAssertEqual(badgeNow, badgeBefore, "\(senders): never in the badge")
            XCTAssertEqual(vm.folderMenu.snapshot.counts[ids.root] ?? 0, rootBefore, "\(senders): never in the root count")
        }
    }

    func testMailWaitingTurnedOffHidesItsCard() async throws {
        let pool = try pool()
        let ids = try await pool.write { db in
            let folders = try InboxFolderFixtures.seed(db)
            _ = try self.seedSplit(db)
            let mail = try self.mailBuiltin(db)
            let card = try self.mailCard(db, mail, senders: ["news@example.com"])
            try db.execute(sql: "UPDATE automations SET enabled = 0 WHERE id = ?", arguments: [mail])
            return (root: folders.root, mail: mail, card: card)
        }
        var vm = await read(pool, folder: ids.root)
        XCTAssertFalse(vm.folderEntries.contains { $0.id == "artifact:\(ids.card)" }, "turned off: its card is left out")
        XCTAssertTrue(vm.folderMenu.snapshot.mailWaiting.turnedOff)

        // Stopped by the daemon (a `disabled_reason`) it is not turned off.
        try await pool.write { db in
            try db.execute(sql: "UPDATE automations SET disabled_reason = 'run would not end' WHERE id = ?",
                           arguments: [ids.mail])
        }
        vm = await read(pool, folder: ids.root)
        XCTAssertTrue(vm.folderEntries.contains { $0.id == "artifact:\(ids.card)" }, "stopped: its last card stays")

        // Attention detection off turns it off whatever the row says.
        vm.disabledFeatures = [InboxFolderQueries.waitingForMeFeatureID]
        await vm.refresh()
        vm.selectFolder(ids.root)
        XCTAssertFalse(vm.folderEntries.contains { $0.id == "artifact:\(ids.card)" }, "feature off: left out")
        XCTAssertTrue(vm.folderMenu.snapshot.mailWaiting.turnedOff)
    }
}
