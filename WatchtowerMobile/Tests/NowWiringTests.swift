import WatchtowerKit
import WatchtowerSync
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

    func testWaitingToSendShowsOnlyWhenAFlushStopped() throws {
        let snapshot = try demoSnapshot(now: now)
        let quiet = NowModel(
            snapshot: snapshot, linked: true, now: now, outbox: OutboxBacklog(queued: 3, undelivered: 0, lastFlushStopped: false))
        XCTAssertNil(quiet.outbox, "a queue the flush is still working through is not shown")
        let stopped = NowModel(
            snapshot: snapshot, linked: true, now: now, outbox: OutboxBacklog(queued: 3, undelivered: 0, lastFlushStopped: true))
        XCTAssertEqual(stopped.outbox?.waitingTitle, "Waiting to send")
        XCTAssertEqual(stopped.outbox?.waitingCount, 3)
        XCTAssertNil(stopped.outbox?.notDeliveredText)
        let empty = NowModel(
            snapshot: snapshot, linked: true, now: now, outbox: OutboxBacklog(queued: 0, undelivered: 0, lastFlushStopped: true))
        XCTAssertNil(empty.outbox, "nothing queued, nothing shown")
        XCTAssertNil(NowModel(snapshot: snapshot, linked: true, now: now).outbox, "a hub on today's path shows neither")
    }

    func testWaitingToSendListsTheQueuedActionsOldestFirst() throws {
        let snapshot = try demoSnapshot(now: now)
        func queued(_ id: String, seq: UInt64, minutesAgo: Double) -> OutboxItem {
            OutboxItem(
                id: id, kind: .sessionStop, entityRecordName: "terminal_session-10", params: [:],
                createdAt: now.addingTimeInterval(-minutesAgo * 60), seq: seq, delivery: .queued, reason: nil)
        }
        let rows = try XCTUnwrap(NowOutboxRows(
            backlog: OutboxBacklog(queued: 4, undelivered: 0, lastFlushStopped: true),
            items: [queued("b", seq: 2, minutesAgo: 90), queued("a", seq: 1, minutesAgo: 120), queued("c", seq: 3, minutesAgo: 60),
                    queued("d", seq: 4, minutesAgo: 30)],
            snapshot: snapshot, now: now, calendar: .current))
        XCTAssertEqual(rows.queued.map(\.id), ["a", "b", "c"], "the first \(NowOutboxRows.queuedLimit)")
        XCTAssertEqual(rows.queued.first?.summary, "Stop “Session report”")
        XCTAssertEqual(rows.queued.first?.time, "Today 10:00")
        XCTAssertEqual(rows.moreText, "1 more")
    }

    func testNotDeliveredRowShowsTheCount() throws {
        let model = NowModel(
            snapshot: try demoSnapshot(now: now), linked: true, now: now,
            outbox: OutboxBacklog(queued: 2, undelivered: 2, lastFlushStopped: false))
        let outbox = try XCTUnwrap(model.outbox)
        XCTAssertEqual(outbox.notDeliveredText, "Not delivered · 2")
        XCTAssertNil(outbox.waitingCount, "the flush has not stopped")
        XCTAssertTrue(model.toneUses.contains { $0.element == "not delivered row" && $0.tone == .red && $0.role == .status })
        XCTAssertFalse(model.toneUses.contains { $0.element.hasPrefix("not delivered") && $0.tone == .orange })
    }
}
