import Foundation
import GRDB
import WatchtowerInterface
import XCTest
@testable import WatchtowerCore
import WatchtowerTestSupport

/// The Inbox's read side on the tower (mobile Inbox spec §5.1, Task 11b):
/// with a loader attached, the folders' lists, their order, counts, row
/// texts and the badge are the feed's; the GRDB read only supplies the
/// records the panes draw.
@MainActor
final class ActionStripFeedTests: XCTestCase {
    private var path = ""
    private var pool: DatabasePool!

    override func setUp() async throws {
        (pool, path) = try TestDatabase.createPool()
    }

    override func tearDown() async throws {
        pool = nil
        TestDatabase.cleanup(path: path)
    }

    private func folder(
        _ id: Int64,
        _ kind: FolderKind,
        count: Int,
        parent: Int64? = nil,
        hidden: Bool = false
    ) -> Folder {
        Folder(id: id, kind: kind, slug: "f\(id)", title: "Folder \(id)", icon: "", parentID: parent, position: Int(id),
               hidden: hidden, count: count, waiting: 0)
    }

    private func artifact(
        _ id: Int64,
        folder: Int64,
        title: String,
        stamp: String,
        runID: Int64,
        refs: [RefFacts] = []
    ) -> Card {
        Card(id: "o\(id)", folderID: folder, cardKind: .artifact, title: title, sourceLine: "Mail summary", preview: "",
             stamp: stamp, living: false, unread: true, priority: "medium", pinned: false,
             automation: CardAutomation(id: 1, name: "Mail summary", builtinID: "", runID: runID),
             blocks: "", body: "", bodyClipped: false, link: "", contentHash: "", actions: [], refFacts: refs)
    }

    private func waitingRef(_ id: Int64) -> RefFacts {
        RefFacts(kind: .inboxItem, id: id, open: true, waits: true, reply: false, replyWaiting: false, link: "",
                 triggerType: "", custom: false, linkedTargetID: 0, ideaKind: "", ideaStatus: "")
    }

    /// Two outputs in GRDB (the records), a VM over them with a loader on
    /// `transport`.
    private func seeded() async throws -> (vm: ActionStripViewModel, older: Int64, newer: Int64, transport: ScriptedFeedTransport) {
        let (older, newer) = try await pool.write { db -> (Int64, Int64) in
            let automation = try TestDatabase.insertAutomation(db, slug: "mail-summary", name: "Mail summary")
            let run = try TestDatabase.insertAutomationRun(db, automationID: automation)
            let older = try TestDatabase.insertAutomationOutput(
                db, automationID: automation, runID: run, title: "Old", createdAt: "2026-10-01T09:00:00Z")
            let newer = try TestDatabase.insertAutomationOutput(
                db, automationID: automation, runID: run, title: "New", createdAt: "2026-10-02T09:00:00Z")
            return (older, newer)
        }
        let transport = ScriptedFeedTransport()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let vm = ActionStripViewModel(dbPool: pool, cliRunner: FakeCLIRunner(), defaults: defaults)
        await vm.refresh()
        let client = TowerClient(transport: transport, clock: ContinuousClock(), restartDaemon: nil, startDaemon: nil)
        vm.attach(InboxFeedLoader(client: client) { FeedRequest() })
        return (vm, older, newer, transport)
    }

    private func settle(_ vm: ActionStripViewModel) async {
        while let read = vm.feedLoader?.pendingRead { await read.value }
        await vm.refresh()
    }

    func testBadgeIsTheRootModelBadge() async throws {
        let (vm, _, _, transport) = try await seeded()
        let root = vm.folderMenu.tree.root.id
        let feed = Feed(v: 1, builtAt: "2026-10-02T10:00:00Z", folders: [
            folder(root, .root, count: 2),
            folder(900, .approvals, count: 3, parent: root),
            folder(901, .owner, count: 4, parent: root),
            folder(902, .owner, count: 7, parent: root, hidden: true)
        ], cards: [])
        transport.answer(feed)

        vm.setOnScreen(true)
        await settle(vm)
        defer { vm.setOnScreen(false) }

        XCTAssertEqual(vm.towerBadge, InboxRootModel(feed: feed, platform: .mac).countBadge)
        XCTAssertEqual(vm.towerBadge, 9, "the Mac badge is the visible folders' counts summed")
        XCTAssertEqual(vm.folderMenu.snapshot.counts[root], 2, "the menu's counts are the feed's")
        XCTAssertEqual(vm.folderMenu.snapshot.counts[901], 4)
    }

    func testTheFolderListIsTheFeedsOrderWithTheMacTexts() async throws {
        let (vm, older, newer, transport) = try await seeded()
        let root = vm.folderMenu.tree.root.id
        // Go lists the older card first: the Mac never re-sorts.
        transport.answer(Feed(v: 1, builtAt: "2026-10-02T10:00:00Z", folders: [folder(root, .root, count: 1)], cards: [
            artifact(older, folder: root, title: "Old", stamp: "2026-10-01T09:00:00Z", runID: 7,
                     refs: [waitingRef(1), waitingRef(2)]),
            artifact(newer, folder: root, title: "New", stamp: "2026-10-02T09:00:00Z", runID: 8),
            artifact(99_999, folder: root, title: "No record yet", stamp: "2026-10-02T09:30:00Z", runID: 9)
        ]))

        vm.setOnScreen(true)
        await settle(vm)
        defer { vm.setOnScreen(false) }

        let rows = vm.folderList.rows
        XCTAssertEqual(rows.map(\.id), ["artifact:\(older)", "artifact:\(newer)"],
                       "feed order; a card whose record is not read yet waits")
        XCTAssertEqual(rows.first?.summary, "2 waiting")
        XCTAssertTrue(rows.first?.detail.hasPrefix("run #7 · ") ?? false)
        XCTAssertEqual(vm.folderEntries.map(\.id), rows.map(\.id))
    }

    func testFolderNavigationReadsTheFeed() async throws {
        let (vm, _, _, transport) = try await seeded()
        let root = vm.folderMenu.tree.root.id
        transport.answer(Feed(v: 1, builtAt: "x", folders: [folder(root, .root, count: 0)], cards: []))
        vm.setOnScreen(true)
        await settle(vm)
        defer { vm.setOnScreen(false) }
        let before = transport.feedCalls.count

        vm.selectFolder(root)
        await settle(vm)

        XCTAssertEqual(transport.feedCalls.count, before + 1)
    }

    func testTheWatchIsOpenOnlyWhileTheInboxIsShownInAWindowOnScreen() async throws {
        let (vm, _, _, transport) = try await seeded()
        XCTAssertEqual(vm.feedLoader?.isOpen, false, "not shown yet")

        vm.setOnScreen(true)
        await transport.until { $0.openWatches == 1 }
        vm.setWindowOnScreen(false)
        XCTAssertEqual(vm.feedLoader?.isOpen, false, "the app went to the tray")
        await transport.until { $0.watchesClosed == 1 }

        vm.setWindowOnScreen(true)
        XCTAssertEqual(vm.feedLoader?.isOpen, true)
        vm.setOnScreen(false)
        XCTAssertEqual(vm.feedLoader?.isOpen, false, "the Inbox view left")
        await settle(vm)
    }

    // MARK: - Writes through inbox.act (Task 11c)

    /// A VM over `pool` that reads and writes through `transport`.
    private func writing(_ transport: ScriptedFeedTransport) async throws -> ActionStripViewModel {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let vm = ActionStripViewModel(dbPool: pool, cliRunner: FakeCLIRunner(), defaults: defaults)
        await vm.refresh()
        await vm.refreshListingEverything()
        let client = TowerClient(transport: transport, clock: ContinuousClock(), restartDaemon: nil, startDaemon: nil)
        vm.attachWrites(InboxTowerWrites(client: client))
        return vm
    }

    func testDoneSendsInboxActWithTheContentHash() async throws {
        let id = try await pool.write { db -> Int64 in
            let automation = try TestDatabase.insertAutomation(db, slug: "mail-summary", name: "Mail summary")
            let run = try TestDatabase.insertAutomationRun(db, automationID: automation)
            return try TestDatabase.insertAutomationOutput(db, automationID: automation, runID: run, contentHash: "h-drawn")
        }
        let transport = ScriptedFeedTransport()
        let vm = try await writing(transport)
        let before = try await pool.read { db in try Row.fetchOne(db, sql: "SELECT * FROM automation_outputs") }

        await vm.markOutputDone(id)

        let act = try XCTUnwrap(transport.acts.last)
        XCTAssertEqual(act.target, "o\(id)")
        XCTAssertEqual(act.verb, .done)
        XCTAssertEqual(act.params.contentHash, "h-drawn", "guarded by the version drawn")
        XCTAssertFalse(act.requestID.isEmpty)
        let after = try await pool.read { db in try Row.fetchOne(db, sql: "SELECT * FROM automation_outputs") }
        XCTAssertEqual(after, before, "the Mac writes nothing itself; Go does")
        XCTAssertNil(vm.lastError)
    }

    func testFailedActionKeepsTheRowWithTheSentenceAndRetry() async throws {
        let id = try await pool.write { db in try TestDatabase.insertInboxItem(db) }
        let transport = ScriptedFeedTransport()
        let vm = try await writing(transport)
        let sentence = "Couldn't mark it done: the database is busy."
        transport.answerActs(refusal: Refusal(code: .changed, sentence: sentence))

        await vm.messageDone(Int(id))

        XCTAssertEqual(vm.rowErrors[.message(Int(id))], InboxRowFailure(message: sentence, press: .done),
                       "the row stays with Go's sentence and Retry repeats Done")
        let first = try XCTUnwrap(transport.acts.last)
        XCTAssertEqual(first.target, "messages")
        XCTAssertEqual(first.params.refKind, .inboxItem)
        XCTAssertEqual(first.params.refID, id)
        XCTAssertEqual(first.params.refVerb, .resolve)

        transport.answerActs()
        await vm.messageDone(Int(id)) // Retry repeats the failed press.

        XCTAssertEqual(transport.acts.count, 2)
        XCTAssertNil(vm.rowErrors[.message(Int(id))])
    }

    func testAVanishedRecordLeavesQuietly() async throws {
        let transport = ScriptedFeedTransport()
        let vm = try await writing(transport)
        transport.answerActs(refusal: Refusal(code: .notFound, sentence: "Couldn't do that: it's no longer on the Mac."))

        await vm.messageDone(4242)

        XCTAssertNil(vm.rowErrors[.message(4242)])
        XCTAssertNil(vm.lastError)
    }

    func testApproveSendsTheDrawnArgsAndEditsAndKeepsAToolFailureOnTheCard() async throws {
        let args = #"{"text":"Ship it","reason":"r"}"#
        let id = try await pool.write { db in try TestDatabase.insertAgentAction(db, argsJSON: args) }
        let transport = ScriptedFeedTransport()
        let vm = try await writing(transport)
        transport.answerActs(ActResult(status: "failed", error: "Slack said no"))

        await vm.approve(id, shownArgs: args, patch: #"{"text":"Ship it now"}"#)

        let act = try XCTUnwrap(transport.acts.last)
        XCTAssertEqual(act.target, "a\(id)")
        XCTAssertEqual(act.verb, .approval)
        XCTAssertEqual(act.params.approvalVerb, .approve)
        XCTAssertEqual(act.params.argsSHA256, AgentActionFeed.argsSHA256(args), "pinned to the args drawn")
        XCTAssertEqual(act.params.patch, try WatchtowerInterface.RawJSON(data: Data(#"{"text":"Ship it now"}"#.utf8)), "Edit… is a patch")
        XCTAssertEqual(vm.actionFeed.rowErrors[id], AgentActionFeed.RowError(verb: "approve", message: "Slack said no"))
        XCTAssertFalse(vm.actionFeed.inFlight.contains(id))

        transport.answerActs(ActResult(status: "applied"))
        await vm.retry(id)
        XCTAssertEqual(transport.acts.last?.params.approvalVerb, .retry)
        XCTAssertNil(vm.actionFeed.rowErrors[id], "a later success clears the card's error")
    }

    func testEveryPressNamesItsButtonKind() async throws {
        let id = try await pool.write { db -> Int64 in
            let automation = try TestDatabase.insertAutomation(db, slug: "triage", name: "Triage")
            let run = try TestDatabase.insertAutomationRun(db, automationID: automation)
            return try TestDatabase.insertAutomationOutput(db, automationID: automation, runID: run, contentHash: "h1")
        }
        let transport = ScriptedFeedTransport()
        let vm = try await writing(transport)

        await vm.pressReply(outputID: id, action: 0, contentHash: "h1")
        let card = try XCTUnwrap(vm.outputRows.first { $0.id == id })
        let target = InboxCardAction.Target(title: "Fix it", intent: nil, parent: nil, hash: "t")
        await vm.proposeTarget(InboxTargetPress(card: card, index: 1, target: target))

        XCTAssertEqual(transport.acts.map(\.verb), [.press, .press])
        XCTAssertEqual(transport.acts.map(\.params.actionKind), ["reply", "target"])
        XCTAssertEqual(transport.acts.map(\.params.index), [0, 1])
        XCTAssertEqual(transport.acts.map(\.params.contentHash), ["h1", "h1"])
    }

    func testMessageSnoozeSendsTheCLIsLocalDate() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let now = Date(timeIntervalSince1970: 1_794_830_400) // 2026-11-16T12:00:00Z = 21:00 in Tokyo
        XCTAssertEqual(ActionStripViewModel.snoozeDate("1d", now: now, calendar: calendar), "2026-11-17")
        XCTAssertEqual(ActionStripViewModel.snoozeDate("1w", now: now, calendar: calendar), "2026-11-23")
        XCTAssertNil(ActionStripViewModel.snoozeDate("soon", now: now, calendar: calendar))
    }
}
