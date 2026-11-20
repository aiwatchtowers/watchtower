import WatchtowerChatText
import WatchtowerKit
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// The phone's live line and the turn's steps (#2112 spec §4, §5): one case per row of §4's table, the tower's
/// freshness, a card standing in, the steps toggle and its closing, Retry, and the record that counts as arrived.
@MainActor
final class WorkchatLiveLineTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var stateAt: Date { now.addingTimeInterval(-194) }

    private func live(conversation: String = "c1", turnActive: Bool = true, current: Bool = true, stepCount: Int = 2) -> SessionFeedLive {
        let steps = (0..<stepCount).map {
            SessionLiveAction(id: "s\($0)", tool: "Read", summary: "file\($0).go", startedAt: now.addingTimeInterval(-60),
                              completedAt: now.addingTimeInterval(-59))
        }
        let running = SessionLiveAction(id: "run", tool: "Bash", summary: "go test ./internal/hub", startedAt: now.addingTimeInterval(-12))
        return SessionFeedLive(
            observedAt: now.addingTimeInterval(-3_600), conversation: conversation, turnAt: now.addingTimeInterval(-107),
            turnActive: turnActive, current: current ? running : nil, steps: steps + (current ? [running] : []), stepsMore: 3
        )
    }

    private func chat(version: Int? = 1, live: SessionFeedLive? = nil, error: String? = nil) -> SessionChat {
        SessionChat(sessionID: 10, live: true, entries: [], activityLive: live, liveVersion: version, liveError: error)
    }

    private func row(
        _ chat: SessionChat?,
        arrived: Bool = true,
        working: Bool = true,
        staleSince: Date? = nil,
        card: Bool = false,
        stepsOpen: Bool = false,
        at: Date? = nil
    ) -> WorkchatLivePresentation.Row? {
        WorkchatLiveLine.row(
            chat: chat, arrivedSinceOpen: arrived, working: working, stateAt: stateAt, staleSince: staleSince,
            cardShown: card, stepsOpen: stepsOpen, now: at ?? now
        )
    }

    private func steps(_ chat: SessionChat?, open: Bool = true, card: Bool = false) -> WorkchatLivePresentation.StepsSlot? {
        WorkchatLiveLine.steps(chat: chat, arrivedSinceOpen: true, working: true, staleSince: nil, cardShown: card,
                               stepsOpen: open, now: now)
    }

    private func heartbeat(_ at: Date, stuckSince: Date? = nil) -> HeartbeatPayload {
        HeartbeatPayload(
            updatedAt: at, appVersion: "1.0", hubID: "hub", macName: "Acme Mac", flavor: .default,
            lastPublishAt: at, lastRelayAt: at, relayBacklog: 0, accounts: [], enabledAt: at, ownerUser: "_user", sharing: .none,
            stuckSince: stuckSince
        )
    }

    func testAStuckKindAloneDoesNotAgeTheLine() throws {
        let beat = now.addingTimeInterval(-5)
        let payload = heartbeat(beat, stuckSince: now.addingTimeInterval(-ReplicaFreshness.stuckAfter - 60))
        let freshness = try XCTUnwrap(ReplicaFreshness(heartbeat: payload, linked: true, relayUnansweredSince: nil, now: now))
        XCTAssertEqual(freshness.state, .stuck)
        XCTAssertNil(WorkchatLiveLine.staleSince(freshness, heartbeat: payload))
        XCTAssertNil(WorkchatLiveLine.staleSince(nil, heartbeat: payload))
    }

    private func session(_ overrides: [String: Any]) throws -> TerminalSessionState {
        try mirror(TerminalSessionState.self, DemoSeed.JSON.session(10, workbench: DemoSeed.acmeID, overrides))
    }

    // MARK: - Spec §4's table

    func testNoRecordSinceOpenSaysLoadingWithTheStateTimer() throws {
        for cached in [nil, chat(live: live())] {
            let line = try XCTUnwrap(row(cached, arrived: false))
            XCTAssertEqual(line.text, "Loading activity…")
            XCTAssertEqual(line.elapsed, "3:14")
            XCTAssertFalse(line.retry)
            XCTAssertNil(line.chevron, "no steps before the first record")
        }
    }

    func testAnOlderHubShowsNoLine() {
        XCTAssertNil(row(chat(version: nil)))
    }

    func testALiveBlockShowsItsRunningStep() throws {
        let line = try XCTUnwrap(row(chat(live: live())))
        XCTAssertEqual(line.symbol, "terminal")
        XCTAssertEqual(line.text, "go test ./internal/hub")
        XCTAssertEqual(line.elapsed, "0:12")
        XCTAssertTrue(line.pulse)
        XCTAssertFalse(line.warning)
        XCTAssertEqual(line.chevron, "chevron.up")
    }

    func testAnObservedAtFromTheHubIsNeverJudgedByAge() throws {
        // The block was read an hour ago and has not changed since: with the tower sending, it is current (C4).
        let line = try XCTUnwrap(row(chat(live: live())))
        XCTAssertFalse(line.text.hasPrefix("Activity out of date"))
    }

    func testAHubReadThatFailedSaysUnavailableWithRetry() throws {
        for block in [nil, live()] {
            let line = try XCTUnwrap(row(chat(live: block, error: "Activity unavailable")))
            XCTAssertEqual(line.text, "Activity unavailable")
            XCTAssertTrue(line.retry)
            XCTAssertTrue(line.warning)
            XCTAssertNil(line.elapsed)
            XCTAssertFalse(line.pulse)
        }
    }

    func testNoTurnSeenYetSaysWorkingWithTheStateTimer() throws {
        let line = try XCTUnwrap(row(chat(live: nil)))
        XCTAssertEqual(line.text, "Working…")
        XCTAssertEqual(line.elapsed, "3:14")
        XCTAssertFalse(line.retry)
    }

    func testBetweenToolsSaysWorkingWithTheTurnTimer() throws {
        var block = live(current: false)
        block.latest = nil
        let line = try XCTUnwrap(row(chat(live: block)))
        XCTAssertEqual(line.text, "Working…")
        XCTAssertEqual(line.elapsed, "1:47")
    }

    func testAnIdleSessionShowsNoLineWhateverTheRecord() {
        let records: [(SessionChat?, Bool)] = [(nil, false), (chat(live: live()), true), (chat(error: "x"), true), (chat(version: nil), true)]
        for (cached, arrived) in records {
            XCTAssertNil(row(cached, arrived: arrived, working: false))
        }
    }

    func testWorkingCountsApprovalsAndBackgroundAgentsAsTheMacDoes() throws {
        XCTAssertTrue(WorkchatLiveLine.working(try session(["state_kind": "working"])))
        XCTAssertTrue(WorkchatLiveLine.working(try session(["state_kind": "needs_approval"])))
        XCTAssertFalse(WorkchatLiveLine.working(try session(["state_kind": "waiting_on_ask"])))
        XCTAssertFalse(WorkchatLiveLine.working(try session(["state_kind": "running"])))
        XCTAssertFalse(WorkchatLiveLine.working(try session(["state_kind": "working", "live": false])))
    }

    // MARK: - Time, freshness, cards

    func testAStepStartedAfterNowCountsFromZero() throws {
        var block = live()
        block.current?.startedAt = now.addingTimeInterval(30)
        XCTAssertEqual(try XCTUnwrap(row(chat(live: block))).elapsed, "0:00")
    }

    func testAStaleTowerSaysOutOfDateWithRetryAndNoTimer() throws {
        let beat = now.addingTimeInterval(-2_400)
        let freshness = try XCTUnwrap(ReplicaFreshness(heartbeat: heartbeat(beat), linked: true, relayUnansweredSince: nil, now: now))
        XCTAssertEqual(freshness.state, .stale)
        let since = WorkchatLiveLine.staleSince(freshness, heartbeat: heartbeat(beat))
        XCTAssertEqual(since, beat)
        for (cached, arrived) in [(chat(live: live()), true), (nil, false), (chat(live: nil), true)] as [(SessionChat?, Bool)] {
            let line = try XCTUnwrap(row(cached, arrived: arrived, staleSince: since))
            XCTAssertEqual(line.text, "Activity out of date · 2400s ago")
            XCTAssertEqual(line.symbol, "clock")
            XCTAssertNil(line.elapsed)
            XCTAssertFalse(line.pulse)
            XCTAssertTrue(line.retry)
            XCTAssertTrue(line.warning)
        }
    }

    func testRelayUnansweredWithARecentHeartbeatIsStillOutOfDate() throws {
        let beat = now.addingTimeInterval(-5)
        let freshness = try XCTUnwrap(ReplicaFreshness(
            heartbeat: heartbeat(beat), linked: true, relayUnansweredSince: now.addingTimeInterval(-90), now: now
        ))
        XCTAssertEqual(freshness.state, .offline)
        let line = try XCTUnwrap(row(chat(live: live()), staleSince: WorkchatLiveLine.staleSince(freshness, heartbeat: heartbeat(beat))))
        XCTAssertEqual(line.text, "Activity out of date · 10s ago")
        XCTAssertNil(line.elapsed)
    }

    func testACardHidesTheLine() {
        XCTAssertNil(row(chat(live: live()), card: true))
        XCTAssertNil(row(nil, arrived: false, card: true))
        XCTAssertNil(steps(chat(live: live()), card: true))
    }

    // MARK: - Steps

    func testStepsAreClosedByDefaultAndOpenOnATap() throws {
        let memory = WorkchatStepsMemory()
        XCTAssertFalse(memory.isOpen(10))
        XCTAssertNil(steps(chat(live: live()), open: memory.isOpen(10)))

        memory.toggle(10, conversation: "c1")
        XCTAssertTrue(memory.isOpen(10))
        XCTAssertFalse(memory.isOpen(11), "the toggle is per session")
        let slot = try XCTUnwrap(steps(chat(live: live()), open: memory.isOpen(10)))
        XCTAssertEqual(slot.title, "This turn · 6 steps")
        XCTAssertEqual(slot.rows.last?.time, "0:12")
        XCTAssertTrue(slot.rows.last?.running == true)

        let line = try XCTUnwrap(row(chat(live: live()), stepsOpen: true))
        XCTAssertEqual(line.text, "This turn · 6 steps")
        XCTAssertEqual(line.symbol, "list.bullet")
        XCTAssertEqual(line.elapsed, "1:47")
        XCTAssertEqual(line.chevron, "chevron.down")

        memory.toggle(10, conversation: "c1")
        XCTAssertFalse(memory.isOpen(10))
    }

    func testStepsCloseAtTurnEndStopCardAndANewConversation() {
        let open = WorkchatLiveLine.StepsWatch(chat: chat(live: live()), working: true, cardShown: false)
        var turnOver = open
        turnOver.turnOver = true
        var idle = open
        idle.working = false
        var card = open
        card.cardShown = true
        var cleared = open
        cleared.conversation = "c2"
        let unread = WorkchatLiveLine.StepsWatch(chat: chat(live: nil, error: "x"), working: true, cardShown: false)
        let memory = WorkchatStepsMemory()

        for (watch, closes) in [(open, false), (unread, false), (turnOver, true), (idle, true), (card, true), (cleared, true)] {
            memory.toggle(10, conversation: "c1")
            memory.note(10, watch)
            XCTAssertEqual(memory.isOpen(10), !closes, "\(watch)")
            memory.close(10)
        }
        memory.toggle(10, conversation: "c1")
        memory.close(10)
        XCTAssertFalse(memory.isOpen(10), "Stop closes it")
    }

    func testTheStringsComeFromTheSharedPresentation() {
        XCTAssertEqual(WorkchatLivePresentation.loading, "Loading activity…")
        XCTAssertEqual(WorkchatLivePresentation.unavailable, "Activity unavailable")
        XCTAssertEqual(WorkchatLivePresentation.working, "Working…")
        XCTAssertEqual(WorkchatLivePresentation.retryTitle, "Retry")
        XCTAssertEqual(WorkchatLivePresentation.stepsToggleHint(open: false), "Show this turn’s steps")
        XCTAssertEqual(WorkchatLivePresentation.stepsToggleHint(open: true), "Hide this turn’s steps")
        XCTAssertEqual(WorkchatLiveLine.warningTone, .red)
    }

    // MARK: - Retry and the record since open

    /// A requester that never ticks, recording each request.
    private final class Sent {
        var routes: [String] = []
    }

    private func requester(_ sent: Sent, now: @escaping () -> Date = Date.init) -> SessionChatRequester {
        let send: (SessionChatRoute) async throws -> Void = { sent.routes.append("\($0.sessionID)") }
        return SessionChatRequester(ticks: { AsyncStream { _ in } }, now: now, send: send)
    }

    func testRetryAsksTheHubAtOnce() async throws {
        let sent = Sent()
        let model = SessionChatViewModel(sessionID: 10, agentID: nil, store: try TestPhone.replica(), requester: requester(sent))
        model.appeared()
        try await poll({ sent.routes == ["10"] }, "no request on appear")
        model.retry()
        try await poll({ sent.routes == ["10", "10"] }, "Retry did not ask at once")
        model.disappeared()
    }

    private func demoStore(_ transport: InMemoryCloudTransport) async throws -> ReplicaStore {
        let store = try makePoolStore(.demo)
        try await DemoSeed.load(into: TestPhone.hub(over: transport, .demo), now: Date())
        _ = try await ReplicaHydrator(transport: transport, store: store).hydrateOnce()
        return store
    }

    func testTheStoredRecordIsNotAnArrivalButTheNextOneIs() async throws {
        let transport = InMemoryCloudTransport()
        let store = try await demoStore(transport)
        let model = SessionChatViewModel(sessionID: 10, agentID: nil, store: store, requester: requester(Sent()))
        model.appeared()
        try await poll({ model.chat != nil }, "the stored record never showed")
        XCTAssertFalse(model.recordArrivedSinceOpen, "the record held from before is not the hub's answer")

        var json = DemoSeed.workingChatPayload(now: Date())
        json["live_error"] = "Activity unavailable"
        try await TestPhone.hub(over: transport, .demo).save([
            try DemoSeed.record(kind: .sessionChat, id: 10, json: json, modifiedAt: Date())
        ])
        _ = try await ReplicaHydrator(transport: transport, store: store).hydrateOnce()
        try await poll({ model.recordArrivedSinceOpen }, "the new record did not count")
        XCTAssertEqual(model.chat?.liveError, "Activity unavailable")
        model.disappeared()
    }

    func testReopeningWithinTheHubsWatchTrustsTheHeldRecord() async throws {
        let transport = InMemoryCloudTransport()
        let store = try await demoStore(transport)
        var clock = Date()
        let sent = Sent()
        let requests = requester(sent) { clock }
        let first = SessionChatViewModel(sessionID: 10, agentID: nil, store: store, requester: requests)
        first.appeared()
        try await poll({ sent.routes.count == 1 && first.chat != nil }, "no request")
        first.disappeared()

        clock += 60
        let again = SessionChatViewModel(sessionID: 10, agentID: nil, store: store, requester: requests)
        again.appeared()
        try await poll({ again.chat != nil && sent.routes.count == 2 }, "the stored record never showed")
        XCTAssertTrue(again.recordArrivedSinceOpen, "the watch opened a minute ago published every change")
        again.disappeared()

        clock += SessionChatRequester.queuedRequestFreshness + 60
        let late = SessionChatViewModel(sessionID: 10, agentID: nil, store: store, requester: requests)
        late.appeared()
        try await poll({ late.chat != nil }, "the stored record never showed")
        XCTAssertFalse(late.recordArrivedSinceOpen, "past the watch the held record may be old")
        late.disappeared()
    }
}
