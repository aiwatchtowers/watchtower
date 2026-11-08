import GRDB
import WatchtowerKit
@testable import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// The Now tab (spec §5.5, mockup 1): the Mac chip, Waiting for you across
/// workbenches (asks with their quick answers, permission requests,
/// stopped and failed sessions; newest first, 20 shown), Working with
/// timers, then the next meeting.
final class NowWiringTests: XCTestCase {
    /// Pinned at local noon today, as the Calendar tests are: an offset of
    /// a few hours never crosses midnight.
    private let now = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date()) ?? Date()

    private func heartbeat(_ at: Date) -> HeartbeatPayload {
        HeartbeatPayload(
            updatedAt: at, appVersion: "1.0", hubID: "hub", macName: "Acme Mac", flavor: .default,
            lastPublishAt: at, lastRelayAt: at, relayBacklog: 0, accounts: [],
            enabledAt: at, ownerUser: "_user", sharing: .none
        )
    }

    private func model(_ snapshot: WorkbenchReplicaSnapshot, linked: Bool = true, at date: Date? = nil) -> NowModel {
        NowModel(snapshot: snapshot, linked: linked, now: date ?? now)
    }

    func testNothingWaitingShowsNothingIsWaiting() throws {
        var snapshot = try demoSnapshot(now: now)
        snapshot.asks = snapshot.asks.filter { $0.status != .open }
        snapshot.sessions = snapshot.sessions.filter { ![.stopped, .finished, .failed].contains($0.stateKind) }
        let model = model(snapshot)
        XCTAssertTrue(model.waitingForYou.isEmpty)
        XCTAssertEqual(model.emptyText, "Nothing is waiting for you")
    }

    func testWaitingRunsAcrossWorkbenchesNewestFirst() throws {
        let model = model(try demoSnapshot(now: now))
        XCTAssertNil(model.emptyText)
        XCTAssertEqual(model.waitingForYou.map(\.id), [
            .ask(111), .ask(109), .ask(110), .session(21), .session(13), .session(15), .session(16)
        ], "session 14 waits on ask #110: only the ask's row shows")
        let question = try XCTUnwrap(model.waitingForYou.first { $0.id == .ask(109) })
        XCTAssertEqual(question.title, "Which menu wording?")
        XCTAssertEqual(question.meta, "Acme · Archive closed targets · ask #109")
        XCTAssertEqual(question.age, "15m")
        XCTAssertEqual(question.glyph, "questionmark")
        XCTAssertEqual(question.destination, .ask(109))
    }

    func testQuickAnswersRideOnTheAskRow() throws {
        let model = model(try demoSnapshot(now: now))
        let question = try XCTUnwrap(model.waitingForYou.first { $0.id == .ask(109) })
        XCTAssertEqual(question.options, [
            InlineAskOption(id: "Archive Closed Targets Now", label: "Archive Closed Targets Now", isRecommended: true),
            InlineAskOption(id: "Archive Now", label: "Archive Now")
        ])
        XCTAssertEqual(model.waitingForYou.first { $0.id == .ask(111) }?.options, [], "a check opens its form")
    }

    func testStoppedFinishedAndFailedSessionsAreWaitingForYou() throws {
        let model = model(try demoSnapshot(now: now))
        let failed = try XCTUnwrap(model.waitingForYou.first { $0.id == .session(16) })
        XCTAssertEqual(failed.title, "Undo archive — failed")
        XCTAssertEqual(failed.meta, "Acme · Error: rate limit")
        XCTAssertEqual(failed.glyph, "exclamationmark")
        XCTAssertEqual(failed.tone, .red)
        XCTAssertEqual(failed.destination, .session(16))
        let stopped = try XCTUnwrap(model.waitingForYou.first { $0.id == .session(15) })
        XCTAssertEqual(stopped.title, "Lane totals — stopped")
        XCTAssertEqual(stopped.tone, .secondary)
        let finished = try XCTUnwrap(model.waitingForYou.first { $0.id == .session(13) }, "a finished session waits for a look")
        XCTAssertEqual(finished.title, "Per-lane fold — finished")
        XCTAssertEqual(finished.meta, "Acme · “Folded done targets per lane.”")
        XCTAssertEqual(finished.glyph, "checkmark")
        XCTAssertEqual(finished.tone, .blue)
        XCTAssertFalse(model.waitingForYou.contains { $0.id == .session(17) }, "a session that never ran is not waiting")
    }

    /// Owner decision (ask #622): an ended session with an open ask is one waiting thing, shown as the ask.
    func testAnEndedSessionWithAnOpenAskShowsOnlyTheAsk() throws {
        var snapshot = WorkbenchReplicaSnapshot()
        snapshot.sessions = [try mirror(TerminalSessionState.self, DemoSeed.JSON.session(50, workbench: DemoSeed.acmeID, [
            "title": "Lane totals", "state_kind": "finished", "state_caption": "Finished", "state_tone": "blue", "live": false,
            "open_asks": 1, "state_at": DemoSeed.JSON.stamp(now.addingTimeInterval(-120)),
            "last_active_at": DemoSeed.JSON.stamp(now.addingTimeInterval(-120))
        ]))]
        snapshot.asks = [try mirror(OwnerAsk.self, DemoSeed.JSON.ask(70, workbench: DemoSeed.acmeID, [
            "session_id": 50, "created_at": DemoSeed.JSON.stamp(now.addingTimeInterval(-60))
        ]))]
        let model = model(snapshot)
        XCTAssertEqual(model.waitingForYou.map(\.id), [.ask(70)])
        XCTAssertEqual(model.waitingCount, 1)

        snapshot.asks = []
        XCTAssertEqual(self.model(snapshot).waitingForYou.map(\.id), [.session(50)], "with the ask answered the session waits again")
    }

    func testAnEndedSessionLeavesNowAfterADay() throws {
        var snapshot = try demoSnapshot(now: now)
        snapshot.sessions.append(try mirror(TerminalSessionState.self, DemoSeed.JSON.session(40, workbench: DemoSeed.acmeID, [
            "title": "Old stop", "state_kind": "stopped", "state_caption": "Stopped", "state_tone": "secondary", "live": false,
            "is_ring": true, "state_at": DemoSeed.JSON.stamp(now.addingTimeInterval(-25 * 3_600)),
            "last_active_at": DemoSeed.JSON.stamp(now.addingTimeInterval(-25 * 3_600))
        ])))
        snapshot.sessions.append(try mirror(TerminalSessionState.self, DemoSeed.JSON.session(41, workbench: DemoSeed.acmeID, [
            "title": "Recent stop", "state_kind": "stopped", "state_caption": "Stopped", "state_tone": "secondary", "live": false,
            "is_ring": true, "state_at": DemoSeed.JSON.stamp(now.addingTimeInterval(-23 * 3_600)),
            "last_active_at": DemoSeed.JSON.stamp(now.addingTimeInterval(-23 * 3_600))
        ])))
        let ids = model(snapshot).waitingForYou.map(\.id)
        XCTAssertFalse(ids.contains(.session(40)), "a stop older than \(NowModel.endedSessionWindow) s is gone")
        XCTAssertTrue(ids.contains(.session(41)))
    }

    func testAPendingRequestIsARowOfItsOwn() throws {
        var snapshot = try demoSnapshot(now: now)
        snapshot.permissionRequests = [try mirror(PermissionRequest.self, permissionRequestJSON(7, session: 12, [
            "summary": "go test ./internal/billing/...\nRun the tests", "created_at": DemoSeed.JSON.stamp(now.addingTimeInterval(-60))
        ]))]
        let request = try XCTUnwrap(model(snapshot).waitingForYou.first)
        XCTAssertEqual(request.id, .request(7))
        XCTAssertEqual(request.title, "Needs approval: Bash")
        XCTAssertEqual(request.code, "go test ./internal/billing/...")
        XCTAssertEqual(request.meta, "Acme · Board lanes")
        XCTAssertEqual(request.glyph, "hand.raised.fill")
        XCTAssertEqual(request.destination, .session(12))
    }

    func testOnlyTheNewestTwentyAreShown() throws {
        var snapshot = WorkbenchReplicaSnapshot()
        for index in 0..<25 {
            snapshot.asks.append(try mirror(OwnerAsk.self, DemoSeed.JSON.ask(Int64(index + 1), workbench: 1, [
                "created_at": DemoSeed.JSON.stamp(now.addingTimeInterval(-Double(index) * 60))
            ])))
        }
        let model = model(snapshot)
        XCTAssertEqual(model.waitingForYou.count, 20)
        XCTAssertEqual(model.waitingForYou.first?.id, .ask(1))
        XCTAssertEqual(model.waitingMore, 5)
    }

    func testWorkingListsLiveWorkingSessionsWithTimers() throws {
        var snapshot = try demoSnapshot(now: now)
        snapshot.heartbeat = heartbeat(now)
        let working = model(snapshot).working
        XCTAssertEqual(working.map(\.id), [10, 20], "working and running, newest activity first")
        XCTAssertEqual(working.first?.title, "Session report")
        XCTAssertEqual(working.first?.meta, "Acme · Working · running tests")
        XCTAssertEqual(working.first?.time, "3:14")

        let asleep = model(snapshot, at: now.addingTimeInterval(2_160)).working
        XCTAssertEqual(asleep.first?.time, "as of 36 min ago", "the Mac away stops the count")
    }

    func testMacReachabilityFollowsTheHeartbeat() {
        XCTAssertEqual(MacReachability.of(heartbeat: now, linked: true, now: now.addingTimeInterval(2_099)), .online)
        XCTAssertEqual(MacReachability.of(heartbeat: now, linked: true, now: now.addingTimeInterval(-60)), .online, "ahead of the phone's clock")
        XCTAssertEqual(MacReachability.of(heartbeat: now, linked: true, now: now.addingTimeInterval(2_100)), .asleep(lastSeen: now))
        XCTAssertEqual(MacReachability.of(heartbeat: nil, linked: true, now: now), .offline)
        XCTAssertEqual(MacReachability.of(heartbeat: now, linked: false, now: now), .offline)
    }

    func testTheMacChipFollowsTheHeartbeat() throws {
        var snapshot = try demoSnapshot(now: now)
        XCTAssertEqual(model(snapshot).chip.text, "Mac · offline")
        XCTAssertEqual(model(snapshot, linked: false).chip.text, "No Mac linked")
        snapshot.heartbeat = heartbeat(now)
        XCTAssertEqual(model(snapshot, at: now.addingTimeInterval(12)).chip.text, "Acme Mac · online")
        XCTAssertEqual(model(snapshot, at: now.addingTimeInterval(12)).chip.tone, .green)
        XCTAssertEqual(model(snapshot, at: now.addingTimeInterval(2_160)).chip.text, "Acme Mac · asleep · last seen 36 min ago")
    }

    // MARK: - The outbox (relay client Phase 1, mockup 5a)

    private func outboxItem(_ id: String, seq: UInt64, _ delivery: Delivery, minutesAgo: Double = 0) -> OutboxItem {
        OutboxItem(
            id: id, kind: .sessionStop, entityRecordName: "terminal_session-10", params: [:],
            createdAt: now.addingTimeInterval(-minutesAgo * 60), seq: seq, delivery: delivery,
            reason: delivery == .undelivered ? .refused : nil)
    }

    private func outbox(
        stopped: Bool, queued: [OutboxItem], undelivered: [OutboxItem] = []
    ) throws -> NowOutboxRows? {
        NowOutboxRows(
            lastFlushStopped: stopped, queued: queued, undelivered: undelivered, snapshot: try demoSnapshot(now: now),
            now: now, calendar: .current)
    }

    func testWaitingToSendShowsOnlyWhenAFlushStopped() throws {
        let three = (1...3).map { outboxItem("q\($0)", seq: UInt64($0), .queued) }
        XCTAssertNil(try outbox(stopped: false, queued: three), "a queue the flush is still working through is not shown")
        let stopped = try XCTUnwrap(try outbox(stopped: true, queued: three))
        XCTAssertEqual(stopped.waitingTitle, "Waiting to send")
        XCTAssertEqual(stopped.waitingCount, 3, "the count is the queued rows'")
        XCTAssertNil(stopped.notDeliveredText)
        XCTAssertNil(try outbox(stopped: true, queued: []), "nothing queued, nothing shown")
        XCTAssertNil(
            NowModel(
                snapshot: try demoSnapshot(now: now), linked: true, now: now,
                backlog: OutboxBacklog(queued: 3, sent: 0, undelivered: 0, lastFlushStopped: true, feedParkedSince: nil)
            ).outbox,
            "a snapshot without ordered rows (today's path) shows neither")
    }

    func testWaitingToSendListsTheOldestQueuedActions() throws {
        let rows = try XCTUnwrap(try outbox(stopped: true, queued: [
            outboxItem("a", seq: 1, .queued, minutesAgo: 120), outboxItem("b", seq: 2, .queued, minutesAgo: 90),
            outboxItem("c", seq: 3, .queued, minutesAgo: 60), outboxItem("d", seq: 4, .queued, minutesAgo: 30)
        ]))
        XCTAssertEqual(rows.waitingCount, 4)
        XCTAssertEqual(rows.queued.map(\.id), ["a", "b", "c"], "the first \(NowOutboxRows.queuedLimit)")
        XCTAssertEqual(rows.queued.first?.summary, "Stop “Session report”")
        XCTAssertEqual(rows.queued.first?.time, "Today 10:00")
        XCTAssertEqual(rows.moreText, "1 more")
    }

    func testNotDeliveredRowShowsTheCount() throws {
        let rows = try XCTUnwrap(try outbox(
            stopped: false, queued: [outboxItem("q", seq: 3, .queued)],
            undelivered: [outboxItem("a", seq: 1, .undelivered), outboxItem("b", seq: 2, .undelivered)]))
        XCTAssertEqual(rows.notDeliveredText, "Not delivered · 2")
        XCTAssertNil(rows.waitingCount, "the flush has not stopped")
        XCTAssertTrue(rows.toneUses.contains { $0.element == "not delivered row" && $0.tone == .red && $0.role == .status })
        XCTAssertFalse(rows.toneUses.contains { $0.tone == .orange })
    }

    // MARK: - The parked feed (relay client Phase 5 Task 16, S58)

    private static let parkedTail = "If this lasts, open Watchtower on the Mac."

    /// A replica whose outbox holds `sent` written, unanswered actions, the feed parked when `parked`.
    private func replica(sent: Int, parked: Bool = true) async throws -> ReplicaStore {
        let store = try TestPhone.replica()
        let outbox = ActionOutbox(transport: try TestPhone.transport(), store: store, deviceID: DemoSeed.device.deviceID)
        try await outbox.enableOrderedActions()
        for target in 0..<sent {
            let params = BoardTargetStatusParams(workbenchID: DemoSeed.acmeID, status: .done, fromStatus: .todo)
            _ = try await outbox.enqueue(
                kind: .boardTargetStatus, entityRecordName: SliceKind.workbenchTarget.recordName(id: "\(410 + target)"),
                params: try params.wireParams())
            _ = try await outbox.flush()
        }
        if parked { try store.markRelayFeedParked(at: now) }
        return store
    }

    /// Now's model over the replica's backlog, as the session reads it.
    private func model(_ store: ReplicaStore, macName: String, lastFlushStopped: Bool = false) throws -> NowModel {
        var backlog = OutboxBacklog.empty
        backlog.lastFlushStopped = lastFlushStopped
        backlog.apply(try store.reader.read { try OutboxBacklog.Counts.read(store, $0) })
        return NowModel(snapshot: try demoSnapshot(now: now), linked: true, now: now, backlog: backlog, macName: macName)
    }

    func testNowShowsTheParkedRowWithSentCount() async throws {
        let store = try await replica(sent: 2)
        let parked = try XCTUnwrap(try model(store, macName: "Work Mac").outbox?.parked)
        XCTAssertEqual(parked.title, "Waiting for new keys from Work Mac")
        XCTAssertEqual(
            parked.detail,
            "2 actions have no answer yet. They finish once it sends them. If this lasts, open Watchtower on the Mac.")
    }

    func testOneSentActionReadsSingular() async throws {
        let store = try await replica(sent: 1)
        let parked = try XCTUnwrap(try model(store, macName: "Work Mac").outbox?.parked)
        XCTAssertEqual(parked.detail, "1 action has no answer yet. It finishes once it sends it. \(Self.parkedTail)")
    }

    func testNoSentActionsOmitsTheCountSentences() async throws {
        let store = try await replica(sent: 0)
        let parked = try XCTUnwrap(try model(store, macName: "Work Mac").outbox?.parked, "parked with nothing sent still shows")
        XCTAssertEqual(parked.title, "Waiting for new keys from Work Mac")
        XCTAssertEqual(parked.detail, Self.parkedTail)
        XCTAssertEqual(NowParkedRow(macName: "", sent: 0).title, "Waiting for new keys from your Mac", "no name yet")
    }

    func testTwoMacsEachNameTheirOwn() async throws {
        let work = try await replica(sent: 2)
        let home = try await replica(sent: 1)
        let idle = try await replica(sent: 1, parked: false)
        XCTAssertEqual(try model(work, macName: "Work Mac").outbox?.parked?.title, "Waiting for new keys from Work Mac")
        XCTAssertEqual(try model(home, macName: "Home Mac").outbox?.parked?.title, "Waiting for new keys from Home Mac")
        XCTAssertEqual(try model(home, macName: "Home Mac").outbox?.parked?.detail.hasPrefix("1 action has"), true)
        XCTAssertNil(try model(idle, macName: "Studio Mac").outbox, "a Mac whose feed reads shows nothing")
    }

    @MainActor
    func testTheRowGoesOnAMerge() async throws {
        let store = try await replica(sent: 2, parked: false)
        var seen: [OutboxBacklog.Counts] = []
        let observation = OutboxBacklog.observe(store: store) { seen.append($0) }
        defer { observation.cancel() }
        try await poll({ seen.last?.sent == 2 }, "the first read")
        XCTAssertNil(seen.last?.feedParkedSince)

        try store.markRelayFeedParked(at: now)
        try await poll({ seen.last?.feedParkedSince != nil }, "the park reaches Now")
        try store.endRelayWait()
        try await poll({ seen.last.map { $0.feedParkedSince == nil } ?? false }, "a read with no pending record clears it")
        var backlog = OutboxBacklog.empty
        backlog.apply(try XCTUnwrap(seen.last))
        XCTAssertNil(
            NowModel(snapshot: try demoSnapshot(now: now), linked: true, now: now, backlog: backlog, macName: "Work Mac").outbox)
    }

    func testNoParkedRowWhileReplayingUnderTheCap() async throws {
        let store = try await replica(sent: 2, parked: false)
        _ = try store.startRelayWait(at: now.addingTimeInterval(-600))
        XCTAssertNil(try model(store, macName: "Work Mac").outbox, "the feed still replays: only the sighting is stamped")
    }

    func testParkedRowUsesNoOrange() async throws {
        let store = try await replica(sent: 2)
        let rows = try XCTUnwrap(try model(store, macName: "Work Mac").outbox)
        XCTAssertEqual(rows.parked?.toneUse, ToneUse(element: "parked feed row", tone: .secondary, role: .info))
        XCTAssertTrue(rows.toneUses.contains { $0.element == "parked feed row" && $0.tone == .secondary && $0.role == .info })
        XCTAssertFalse(rows.toneUses.contains { $0.tone == .orange })
    }

    func testParkedAndWaitingToSendShowTogether() throws {
        let three = (1...3).map { outboxItem("q\($0)", seq: UInt64($0), .queued) }
        let rows = try XCTUnwrap(NowOutboxRows(
            lastFlushStopped: true, queued: three, undelivered: [], snapshot: try demoSnapshot(now: now), now: now,
            calendar: .current, parked: NowParkedRow(macName: "Work Mac", sent: 2)))
        XCTAssertEqual(rows.parked?.title, "Waiting for new keys from Work Mac")
        XCTAssertEqual(rows.waitingCount, 3)
        XCTAssertEqual(rows.toneUses.map(\.element), ["parked feed row", "waiting to send count"], "the parked row first")
    }

    // MARK: - The Relay banner (relay client Phase 4 Task 10)

    func testTheBannerSitsAboveWaitingToSend() {
        XCTAssertEqual(NowView.topBlocks, [.chip, .relayBanner, .outbox])
    }

    @MainActor
    func testSubscribeOpensTheSheet() async throws {
        var opened = 0
        XCTAssertNil(RelayBannerPress.run(.subscribe, session: nil, center: nil) { opened += 1 })
        XCTAssertEqual(opened, 1)
        XCTAssertNil(RelayBannerPress.run(.confirmPurchase, session: nil, center: nil) { opened += 1 })
        XCTAssertEqual(opened, 2)
    }

    /// Restore goes through the card's press: the product's load first, the restore, and the sheet shows its result.
    @MainActor
    func testRestoreOpensTheSheetAndRestores() async throws {
        let bed = AccountBed()
        _ = try await bed.register()
        bed.store.productResult = RelayProduct(id: "relay", displayPrice: "$4.99")
        let center = bed.makeCenter()
        center.start()
        await center.foreground()?.value
        var opened = 0
        let press = RelayBannerPress.run(.restore, session: nil, center: center) { opened += 1 }
        XCTAssertEqual(opened, 1, "the sheet opens at once, so its S44 shows")
        _ = await press?.value
        XCTAssertEqual(bed.store.restoreCalls, 1)
        XCTAssertEqual(center.purchase, .noSubscriptionFound)
        XCTAssertNotNil(center.product, "the load went first: S45 can sell")
    }
}
