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
               hidden: hidden, ownHidden: hidden, count: count, waiting: 0)
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

    /// `seeded()` on a client whose clock the test moves.
    private struct OnTestClock {
        let vm: ActionStripViewModel
        let newer: Int64
        let transport: ScriptedFeedTransport
        let clock: TowerTestClock
    }

    private func seededOnTestClock() async throws -> OnTestClock {
        let (vm, _, newer, _) = try await seeded()
        let transport = ScriptedFeedTransport()
        let clock = TowerTestClock()
        let client = TowerClient(transport: transport, clock: clock, restartDaemon: nil, startDaemon: nil)
        vm.attach(InboxFeedLoader(client: client) { FeedRequest() })
        return OnTestClock(vm: vm, newer: newer, transport: transport, clock: clock)
    }

    private func settle(_ vm: ActionStripViewModel) async {
        while let read = vm.feedLoader?.pendingRead { await read.value }
        await vm.refresh()
    }

    /// A route to a day Go does not list (no briefing, no plan) selects
    /// nothing: the Mac lists only what Go lists. The feed is asked for the
    /// day (`FeedRequest.day`), which Go lists when it has a record
    /// (`TestLegacy_OpenDayListedOnlyWithARecord`); choosing another folder
    /// drops it.
    func testARouteToADayGoDoesNotListSelectsNothing() async throws {
        let (vm, _, _, transport) = try await seeded()
        transport.answer(Feed(v: 1, builtAt: "2026-11-16T09:00:00Z", folders: [folder(1, .root, count: 0)], cards: []))
        vm.feedLoader?.reload()
        await settle(vm)

        await vm.open(folder: nil, select: .card(.day("2026-11-10")))

        XCTAssertNil(vm.selection, "not found: nothing selected")
        XCTAssertNil(vm.entrySelection)
        XCTAssertFalse(vm.folderEntries.contains { $0.id == "day:2026-11-10" }, "Swift lists no row Go did not list")
        XCTAssertEqual(transport.feedCalls.last?.day, "2026-11-10", "the feed is asked for the day")
        vm.selectFolder(1)
        XCTAssertNil(vm.openDay, "choosing a folder drops the day")
    }

    /// The loader's own transitions (mockup §7), not a seam: the daemon
    /// goes away while the list is on screen, the client reconnects, and
    /// once the tower has been down 1 s "Reconnecting to Watchtower…" shows
    /// above the last list; the tower back, the line goes and the list is
    /// current again.
    func testReconnectingLineAboveTheLastList() async throws {
        let rig = try await seededOnTestClock()
        let (vm, newer, transport, clock) = (rig.vm, rig.newer, rig.transport, rig.clock)
        transport.answer(Feed(v: 1, builtAt: "2026-11-16T09:00:00Z", folders: [folder(1, .root, count: 1)], cards: [
            artifact(newer, folder: 1, title: "New", stamp: "2026-10-02T09:00:00Z", runID: 1)
        ]))
        let loader = try XCTUnwrap(vm.feedLoader)
        loader.open()
        await settle(vm)
        defer { loader.close() }
        XCTAssertEqual(vm.folderEntries.map(\.id), ["artifact:\(newer)"])
        XCTAssertNil(vm.feedStatus(now: Date()))

        transport.goDown(true)
        loader.reload() // the read finds the daemon gone and waits for the link
        await untilObserved { loader.state == .reconnecting }
        XCTAssertNil(vm.feedStatus(now: Date()), "no line before the tower has been down 1 s")
        // The reconnect schedule counts from the drop: moving the clock 1 s
        // runs its hellos up to the 1 s probe (deadlines are absolute).
        clock.advance(by: .milliseconds(1_000))
        await untilObserved { loader.showsReconnectingLine }
        XCTAssertEqual(vm.feedStatus(now: Date()), InboxMacFeedStatus(kind: .reconnecting, text: TowerText.reconnecting))
        XCTAssertEqual(vm.folderEntries.map(\.id), ["artifact:\(newer)"], "the last list stays under the line")

        transport.goDown(false)
        clock.advance(by: .milliseconds(1_000))
        await untilObserved { loader.state == .ready(stale: nil) }
        while let read = loader.pendingRead { await read.value }
        XCTAssertNil(vm.feedStatus(now: Date()), "the tower is back: no line")
    }

    /// A refused read keeps the last list under the reason, naming when that
    /// list was read, with Retry (mockup §7).
    func testAFailedReadKeepsTheListUnderItsLine() async throws {
        let (vm, _, newer, transport) = try await seeded()
        let readAt = try XCTUnwrap(AutomationDates.parse("2026-11-16T09:14:00Z"))
        vm.feedLoader?.clock = { readAt }
        transport.answer(Feed(v: 1, builtAt: "2026-11-16T09:00:00Z", folders: [folder(1, .root, count: 1)], cards: [
            artifact(newer, folder: 1, title: "New", stamp: "2026-10-02T09:00:00Z", runID: 1)
        ]))
        vm.feedLoader?.reload()
        await settle(vm)
        transport.refuse(Refusal(code: .unsupported, sentence: "The database is busy."))
        vm.feedLoader?.reload()
        await settle(vm)

        let status = try XCTUnwrap(vm.feedStatus(now: readAt))
        XCTAssertEqual(status.kind, .failed)
        XCTAssertEqual(status.actionTitle, TowerText.retry)
        XCTAssertEqual(status.text, TowerText.refreshFailed(reason: "The database is busy", shownAt: readAt,
                                                            timeZone: .current, now: readAt))
        XCTAssertEqual(vm.folderEntries.map(\.id), ["artifact:\(newer)"], "the last list stays")
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

    /// A VM over `pool` listing Go's case `listing` (seeded into the pool;
    /// nil: nothing listed) that writes through `transport`.
    private func writing(_ transport: ScriptedFeedTransport, listing: String?) async throws -> ActionStripViewModel {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let vm = ActionStripViewModel(dbPool: pool, cliRunner: FakeCLIRunner(), defaults: defaults)
        await vm.refresh()
        if let listing { await vm.follow(try FeedCaseTransport.seeded(listing, pool: XCTUnwrap(pool))) }
        let client = TowerClient(transport: transport, clock: ContinuousClock(), restartDaemon: nil, startDaemon: nil)
        vm.attachWrites(InboxTowerWrites(client: client))
        return vm
    }

    /// Propose Reply through the tower is Go's to decide: a row Swift's
    /// `InboxReplyPolicy` copy knows nothing of (not in the local feed, so
    /// no tool) still sends `reply_propose`, and Go builds the tool.
    func testTowerReplyIsNotGatedBySwiftsPolicyCopy() async throws {
        let transport = ScriptedFeedTransport()
        let vm = try await writing(transport, listing: nil)
        vm.startReply(42)
        await vm.proposeReply(42, text: "  On it  ", host: "Waiting for me")

        let act = try XCTUnwrap(transport.acts.last, "the press reached the tower")
        XCTAssertEqual(act.verb, .replyPropose)
        XCTAssertEqual(act.target, "messages")
        XCTAssertEqual(act.params.text, "On it")
        XCTAssertEqual(act.params.refID, 42)
    }

    func testDoneSendsInboxActWithTheContentHash() async throws {
        // Mail summary's output 1, drawn at h-drawn.
        let id: Int64 = 1
        let transport = ScriptedFeedTransport()
        let vm = try await writing(transport, listing: "desktop_feedtest_drawn_output")
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
        // Message 1.
        let id: Int64 = 1
        let transport = ScriptedFeedTransport()
        let vm = try await writing(transport, listing: "desktop_kinds_one_message")
        let sentence = "Couldn't mark it done: the database is busy."
        transport.answerActs(refusal: Refusal(code: .changed, sentence: sentence))

        await vm.messageDone(Int(id))

        XCTAssertEqual(vm.rowErrors[.message(Int(id))], InboxRowFailure(message: sentence, press: .done),
                       "the row stays with Go's sentence and Retry repeats Done")
        XCTAssertNil(vm.lastError, "the failure stays on its row only (mockup §7)")
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
        let vm = try await writing(transport, listing: nil)
        transport.answerActs(refusal: Refusal(code: .notFound, sentence: "Couldn't do that: it's no longer on the Mac."))

        await vm.messageDone(4242)

        XCTAssertNil(vm.rowErrors[.message(4242)])
        XCTAssertNil(vm.lastError)
    }

    /// A message an artifact's row names but Go has closed (`ref_facts`
    /// open false, its record still read by id): a failed write on it leaves
    /// quietly, as a vanished record does.
    func testAFailedWriteOnARowGoClosedLeavesQuietly() async throws {
        // Artifact 1's row is message 1, resolved meanwhile.
        let transport = ScriptedFeedTransport()
        let vm = try await writing(transport, listing: "desktop_rows_closed_message_ref")
        XCTAssertTrue(vm.feed.messages.contains { $0.item.id == 1 }, "the record is read by id")
        transport.answerActs(refusal: Refusal(code: .changed, sentence: "Couldn't mark it done: it changed."))

        await vm.messageDone(1)

        XCTAssertNil(vm.rowErrors[.message(1)])
        XCTAssertNil(vm.lastError)
    }

    func testApproveSendsTheDrawnArgsAndEditsAndKeepsAToolFailureOnTheCard() async throws {
        let args = #"{"text":"Ship it","reason":"r"}"#
        // Action 1 with `args`.
        let id: Int64 = 1
        let transport = ScriptedFeedTransport()
        let vm = try await writing(transport, listing: "desktop_feedtest_action_ship_it")
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
        // Triage's output 1, drawn at h1.
        let id: Int64 = 1
        let transport = ScriptedFeedTransport()
        let vm = try await writing(transport, listing: "desktop_feedtest_triage_output")

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
