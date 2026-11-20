import WatchtowerChatText
import WatchtowerKit
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// The phone's live line and the turn's steps (#2112 spec §4, §5): one case per row of §4's table, the tower's
/// freshness, a card standing in, the steps toggle and its closing, a subagent's line, Retry, and the record that
/// answers this opening (`open_id`).
@MainActor
final class WorkchatLiveLineTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var stateAt: Date { now.addingTimeInterval(-194) }
    private let route = SessionChatRoute(sessionID: 10, agentID: nil)

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

    private func chat(version: Int? = 1, live: SessionFeedLive? = nil, error: String? = nil, openID: String? = nil) -> SessionChat {
        SessionChat(sessionID: 10, live: true, entries: [], activityLive: live, liveVersion: version, liveError: error, openID: openID)
    }

    private func inputs(
        _ chat: SessionChat?,
        arrived: Bool = true,
        working: Bool = true,
        staleSince: Date? = nil,
        card: Bool = false,
        stepsOpen: Bool = false
    ) -> WorkchatLiveLine.Inputs {
        WorkchatLiveLine.Inputs(chat: chat, arrivedSinceOpen: arrived, working: working, stateAt: stateAt, staleSince: staleSince,
                                cardShown: card, stepsOpen: stepsOpen)
    }

    private func row(
        _ chat: SessionChat?,
        arrived: Bool = true,
        working: Bool = true,
        staleSince: Date? = nil,
        card: Bool = false,
        stepsOpen: Bool = false
    ) -> WorkchatLivePresentation.Row? {
        WorkchatLiveLine.row(
            inputs(chat, arrived: arrived, working: working, staleSince: staleSince, card: card, stepsOpen: stepsOpen), now: now
        )
    }

    private func steps(_ chat: SessionChat?, open: Bool = true, card: Bool = false) -> WorkchatLivePresentation.StepsSlot? {
        WorkchatLiveLine.steps(inputs(chat, card: card, stepsOpen: open), now: now)
    }

    private func heartbeat(_ at: Date, stuckSince: Date? = nil) -> HeartbeatPayload {
        HeartbeatPayload(
            updatedAt: at, appVersion: "1.0", hubID: "hub", macName: "Acme Mac", flavor: .default,
            lastPublishAt: at, lastRelayAt: at, relayBacklog: 0, accounts: [], enabledAt: at, ownerUser: "_user", sharing: .none,
            stuckSince: stuckSince
        )
    }

    private func session(_ overrides: [String: Any]) throws -> TerminalSessionState {
        try mirror(TerminalSessionState.self, DemoSeed.JSON.session(10, workbench: DemoSeed.acmeID, overrides))
    }

    // MARK: - Spec §4's table

    func testNoRecordForThisOpeningSaysLoadingWithTheStateTimer() throws {
        for cached in [nil, chat(live: live(), openID: "earlier")] {
            let line = try XCTUnwrap(row(cached, arrived: false))
            XCTAssertEqual(line.text, "Loading activity…")
            XCTAssertEqual(line.elapsed, "3:14")
            XCTAssertFalse(line.retry)
            XCTAssertNil(line.chevron, "no steps before the first record")
        }
    }

    func testAnOlderHubShowsNoLineEvenBehindAStaleTower() {
        XCTAssertNil(row(chat(version: nil)))
        XCTAssertNil(row(chat(version: nil), staleSince: now.addingTimeInterval(-2_400)))
        XCTAssertNil(row(chat(version: nil), arrived: false, staleSince: now.addingTimeInterval(-2_400)))
    }

    func testNoRecordBehindAStaleTowerShowsNoLine() {
        XCTAssertNil(row(nil, arrived: false, staleSince: now.addingTimeInterval(-2_400)),
                     "nothing says the hub is live-capable yet")
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

    func testASubagentWorksUntilItsOwnTurnEnds() throws {
        let busy = try session(["state_kind": "working"])
        XCTAssertTrue(WorkchatLiveLine.working(busy, subagent: chat(live: live()), staleSince: nil))
        XCTAssertTrue(WorkchatLiveLine.working(busy, subagent: nil, staleSince: nil), "no record yet: Loading while the session works")
        XCTAssertFalse(WorkchatLiveLine.working(busy, subagent: chat(live: live(turnActive: false)), staleSince: nil))
        XCTAssertFalse(WorkchatLiveLine.working(try session(["state_kind": "waiting_on_ask"]), subagent: chat(live: live()), staleSince: nil))
    }

    func testOnlyACurrentBlockSaysTheSubagentStopped() throws {
        let busy = try session(["state_kind": "working"])
        let over = live(turnActive: false)
        let failed = chat(live: over, error: "Activity unavailable")
        XCTAssertTrue(WorkchatLiveLine.working(busy, subagent: failed, staleSince: nil), "a failed read cannot say it stopped")
        let unavailable = try XCTUnwrap(row(failed, working: WorkchatLiveLine.working(busy, subagent: failed, staleSince: nil)))
        XCTAssertEqual(unavailable.text, "Activity unavailable")
        XCTAssertTrue(unavailable.retry)

        let since = now.addingTimeInterval(-2_400)
        XCTAssertTrue(WorkchatLiveLine.working(busy, subagent: chat(live: over), staleSince: since), "nor a stale tower's")
        let stale = try XCTUnwrap(row(chat(live: over), working: true, staleSince: since))
        XCTAssertEqual(stale.text, "Activity out of date · 40m ago")
        XCTAssertTrue(stale.retry)
    }

    // MARK: - Time, freshness, cards

    func testAStepStartedAfterNowCountsFromZero() throws {
        var block = live()
        block.current?.startedAt = now.addingTimeInterval(30)
        XCTAssertEqual(try XCTUnwrap(row(chat(live: block))).elapsed, "0:00")
    }

    func testAStaleTowerSaysOutOfDateByTheRealAgeWithRetryAndNoTimer() throws {
        let beat = now.addingTimeInterval(-2_400)
        let freshness = try XCTUnwrap(ReplicaFreshness(heartbeat: heartbeat(beat), linked: true, relayUnansweredSince: nil, now: now))
        XCTAssertEqual(freshness.state, .stale)
        XCTAssertEqual(freshness.staleSince, beat)
        let records: [(SessionChat?, Bool)] = [(chat(live: live()), true), (chat(live: live(), openID: "earlier"), false), (chat(live: nil), true)]
        for (cached, arrived) in records {
            let line = try XCTUnwrap(row(cached, arrived: arrived, staleSince: freshness.staleSince))
            XCTAssertEqual(line.text, "Activity out of date · 40m ago")
            XCTAssertEqual(line.symbol, "clock")
            XCTAssertNil(line.elapsed)
            XCTAssertFalse(line.pulse)
            XCTAssertTrue(line.retry)
            XCTAssertTrue(line.warning)
        }
    }

    func testTheTowerFreshnessIsTheReplicaFreshnessLines() throws {
        let beat = now.addingTimeInterval(-90)
        let offline = TowerFreshness(heartbeat: heartbeat(beat), linked: true, relayUnansweredSince: now.addingTimeInterval(-90))
        XCTAssertEqual(offline.freshness(at: now)?.state, .offline)
        XCTAssertEqual(offline.staleSince(at: now), beat)
        let stuck = TowerFreshness(heartbeat: heartbeat(now, stuckSince: now.addingTimeInterval(-ReplicaFreshness.stuckAfter - 60)), linked: true)
        XCTAssertEqual(stuck.freshness(at: now)?.state, .stuck)
        XCTAssertNil(stuck.staleSince(at: now), "a kind stuck alone does not age the line")
        XCTAssertNil(TowerFreshness(heartbeat: heartbeat(now), linked: true).staleSince(at: now))
        XCTAssertEqual(WorkchatLiveLine.warningToneUse.tone, ReplicaFreshness.tone)
        XCTAssertEqual(WorkchatLiveLine.warningToneUse.role, .status)
    }

    func testACardHidesTheLine() {
        XCTAssertNil(row(chat(live: live()), card: true))
        XCTAssertNil(row(nil, arrived: false, card: true))
        XCTAssertNil(steps(chat(live: live()), card: true))
    }

    // MARK: - Steps

    private func watch(_ block: SessionFeedLive?, working: Bool = true, card: Bool = false) -> WorkchatLiveLine.StepsWatch {
        WorkchatLiveLine.StepsWatch(chat: chat(live: block), working: working, cardShown: card)
    }

    func testStepsAreClosedByDefaultAndOpenOnATap() throws {
        let memory = WorkchatStepsMemory()
        XCTAssertFalse(memory.isOpen(route))
        XCTAssertNil(steps(chat(live: live()), open: memory.isOpen(route)))

        memory.toggle(route, watch(live()))
        XCTAssertTrue(memory.isOpen(route))
        XCTAssertFalse(memory.isOpen(SessionChatRoute(sessionID: 11, agentID: nil)), "the toggle is per chat")
        let slot = try XCTUnwrap(steps(chat(live: live()), open: memory.isOpen(route)))
        XCTAssertEqual(slot.title, "This turn · 6 steps")
        XCTAssertEqual(slot.rows.last?.time, "0:12")
        XCTAssertTrue(slot.rows.last?.running == true)

        let line = try XCTUnwrap(row(chat(live: live()), stepsOpen: true))
        XCTAssertEqual(line.text, "This turn · 6 steps")
        XCTAssertEqual(line.symbol, "list.bullet")
        XCTAssertEqual(line.elapsed, "1:47")
        XCTAssertEqual(line.chevron, "chevron.down")

        memory.toggle(route, watch(live()))
        XCTAssertFalse(memory.isOpen(route))
    }

    func testStepsCloseAtTurnEndCardNewConversationAndNewTurn() {
        var newTurn = live()
        newTurn.turnAt = now.addingTimeInterval(-5)
        let cases: [(WorkchatLiveLine.StepsWatch, Bool, String)] = [
            (watch(live()), false, "the same turn"),
            (WorkchatLiveLine.StepsWatch(chat: chat(error: "x"), working: true, cardShown: false), false, "a failed read hides it"),
            (watch(live(turnActive: false)), true, "turn end"),
            (watch(live(), working: false), true, "the session stopped"),
            (watch(live(), card: true), true, "a card"),
            (watch(live(conversation: "c2")), true, "a new conversation"),
            (watch(newTurn), true, "a new turn")
        ]
        let memory = WorkchatStepsMemory()
        for (next, closes, what) in cases {
            memory.toggle(route, watch(live()))
            memory.note(route, next)
            XCTAssertEqual(memory.isOpen(route), !closes, what)
            memory.close(route)
        }
    }

    func testAConversationOrTurnAppearingLaterDoesNotClose() {
        let memory = WorkchatStepsMemory()
        var bare = live()
        bare.conversation = ""
        bare.turnAt = nil
        var opened = watch(bare)
        opened.conversation = nil
        memory.toggle(route, opened)
        memory.note(route, watch(live()))
        XCTAssertTrue(memory.isOpen(route))
    }

    func testStopClosesTheStepsOnlyOnceTheStopIsAccepted() async {
        struct Refused: Error {}
        let memory = WorkchatStepsMemory()
        memory.toggle(route, watch(live()))
        do {
            try await memory.close(route) { throw Refused() }
            XCTFail("the refusal must reach the caller")
        } catch {}
        XCTAssertTrue(memory.isOpen(route), "a refused Stop leaves the steps open")
        try? await memory.close(route) {}
        XCTAssertFalse(memory.isOpen(route))
    }

    func testStepsOfRemovedSessionsArePruned() {
        let memory = WorkchatStepsMemory()
        let gone = SessionChatRoute(sessionID: 99, agentID: "a", toolUseID: "t")
        memory.toggle(route, watch(live()))
        memory.toggle(gone, watch(live()))
        memory.prune(keeping: [10, 11])
        XCTAssertTrue(memory.isOpen(route))
        XCTAssertFalse(memory.isOpen(gone))
    }

    func testTheStringsComeFromTheSharedPresentation() {
        XCTAssertEqual(WorkchatLivePresentation.loading, "Loading activity…")
        XCTAssertEqual(WorkchatLivePresentation.unavailable, "Activity unavailable")
        XCTAssertEqual(WorkchatLivePresentation.working, "Working…")
        XCTAssertEqual(WorkchatLivePresentation.retryTitle, "Retry")
        XCTAssertEqual(WorkchatLivePresentation.stepsToggleHint(open: false), "Show this turn’s steps")
        XCTAssertEqual(WorkchatLivePresentation.stepsToggleHint(open: true), "Hide this turn’s steps")
    }

    // MARK: - The record that answers this opening

    /// A requester that never ticks, naming opens "o1", "o2", … and recording each request.
    private final class Sent {
        var requests: [SessionChatRequest] = []
        var next = 0
    }

    private func requester(_ sent: Sent, echoes: Bool = true) -> SessionChatRequester {
        let send: (SessionChatRequest) async throws -> Void = { sent.requests.append($0) }
        let newOpenID: () -> String = {
            sent.next += 1
            return "o\(sent.next)"
        }
        return SessionChatRequester(ticks: { AsyncStream { _ in } }, newOpenID: newOpenID, hubEchoesOpenID: echoes, send: send)
    }

    private func demoStore(_ transport: InMemoryCloudTransport) async throws -> ReplicaStore {
        let store = try makePoolStore(.demo)
        try await DemoSeed.load(into: TestPhone.hub(over: transport, .demo), now: Date())
        _ = try await ReplicaHydrator(transport: transport, store: store).hydrateOnce()
        return store
    }

    private func publish(_ json: [String: Any], over transport: InMemoryCloudTransport, into store: ReplicaStore) async throws {
        try await TestPhone.hub(over: transport, .demo).save([
            try DemoSeed.record(kind: .sessionChat, id: 10, json: json, modifiedAt: Date())
        ])
        _ = try await ReplicaHydrator(transport: transport, store: store).hydrateOnce()
    }

    func testOnlyARecordEchoingThisOpeningEndsLoading() async throws {
        let transport = InMemoryCloudTransport()
        let store = try await demoStore(transport)
        let sent = Sent()
        let model = SessionChatViewModel(sessionID: 10, agentID: nil, store: store, requester: requester(sent))
        var json = DemoSeed.workingChatPayload(now: Date())
        json["open_id"] = "earlier"
        try await publish(json, over: transport, into: store)

        model.appeared()
        try await poll({ model.chat?.openID == "earlier" && sent.requests.count == 1 }, "the stored record never showed")
        XCTAssertEqual(model.openID, "o1")
        XCTAssertEqual(sent.requests.first?.openID, "o1", "the request names this opening")
        XCTAssertFalse(model.recordArrivedSinceOpen, "a record answering an earlier opening is not this one's")

        json["open_id"] = "someone-else"
        try await publish(json, over: transport, into: store)
        try await poll({ model.chat?.openID == "someone-else" }, "the other record never showed")
        XCTAssertFalse(model.recordArrivedSinceOpen)

        json["open_id"] = "o1"
        try await publish(json, over: transport, into: store)
        try await poll({ model.recordArrivedSinceOpen }, "the echo did not end Loading")

        // Another phone's opening comes next: this one stays answered.
        json["open_id"] = "another-phone"
        try await publish(json, over: transport, into: store)
        try await poll({ model.chat?.openID == "another-phone" }, "the other phone's record never showed")
        XCTAssertTrue(model.recordArrivedSinceOpen, "an answered opening does not go back to Loading")
        model.disappeared()

        // Reopened: the record held answers the last opening, not this one.
        model.appeared()
        XCTAssertEqual(model.openID, "o2")
        XCTAssertFalse(model.recordArrivedSinceOpen, "a stored record after reopening stays Loading")
        model.disappeared()
    }

    func testAnOlderHubsRecordCountsAsArrived() async throws {
        let transport = InMemoryCloudTransport()
        let store = try await demoStore(transport)
        var json = DemoSeed.workingChatPayload(now: Date())
        json["open_id"] = nil
        json["activity_live"] = nil
        json["live_version"] = nil
        try await publish(json, over: transport, into: store)
        let model = SessionChatViewModel(sessionID: 10, agentID: nil, store: store, requester: requester(Sent()))
        model.appeared()
        try await poll({ model.chat != nil }, "the stored record never showed")
        XCTAssertTrue(model.recordArrivedSinceOpen, "a hub that echoes no id answers as before")
        model.disappeared()
    }

    func testALiveCapableRecordWithoutAnEchoIsNotTheAnswer() async throws {
        let transport = InMemoryCloudTransport()
        let store = try await demoStore(transport)
        var json = DemoSeed.workingChatPayload(now: Date())
        json["open_id"] = nil
        try await publish(json, over: transport, into: store)
        let model = SessionChatViewModel(sessionID: 10, agentID: nil, store: store, requester: requester(Sent()))
        model.appeared()
        try await poll({ model.chat?.liveVersion == 1 }, "the stored record never showed")
        XCTAssertNil(model.chat?.openID)
        XCTAssertFalse(model.recordArrivedSinceOpen, "a hub that knows the live block echoes the id: wait for it")
        model.disappeared()
    }

    func testTheDemoHoldsItsRecordsAsAnswered() async throws {
        let transport = InMemoryCloudTransport()
        let store = try await demoStore(transport)
        let model = SessionChatViewModel(sessionID: 10, agentID: nil, store: store, requester: requester(Sent(), echoes: false))
        model.appeared()
        try await poll({ model.chat != nil }, "the stored record never showed")
        XCTAssertTrue(model.recordArrivedSinceOpen)
        model.disappeared()
    }

    func testRetryGoesOutAtOnceUnderANewOpeningPastAQueuedRepeat() async throws {
        let store = try makePoolStore()
        let outbox = ActionOutbox(transport: try TestPhone.transport(), store: store, deviceID: DemoSeed.device.deviceID)
        var next = 0
        let requests = SessionChatRequester.sending(through: outbox, store: store, ticks: { AsyncStream { _ in } }, newOpenID: {
            next += 1
            return "o\(next)"
        })
        let model = SessionChatViewModel(sessionID: 10, agentID: nil, store: store, requester: requests)
        func openIDs() -> [String] {
            ((try? store.pendingActions()) ?? []).compactMap {
                if case let .string(id) = $0.action.params["open_id"] { return id }
                return nil
            }
        }
        model.appeared()
        try await poll({ openIDs() == ["o1"] }, "no request on appear")
        model.retry()
        XCTAssertEqual(model.openID, "o2")
        try await poll({ openIDs().sorted() == ["o1", "o2"] }, "Retry waited behind the queued request")
        model.disappeared()
    }
}
