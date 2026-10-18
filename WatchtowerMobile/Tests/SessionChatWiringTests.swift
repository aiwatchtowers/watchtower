import GRDB
import WatchtowerKit
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// The phone's session chat (board #486, FEED-05): the request on appear and
/// every 60 s, the screen's states, the subagent route and the Tell bar rule.
@MainActor
final class SessionChatWiringTests: XCTestCase {
    private let now = Date()

    /// A requester whose ticks the test fires, recording what it sent.
    private final class Spy {
        var sent: [String] = []
        var tick: AsyncStream<Void>.Continuation?
    }

    private func requester(_ spy: Spy) -> SessionChatRequester {
        SessionChatRequester(
            ticks: {
                AsyncStream { spy.tick = $0 }
            },
            send: { route in spy.sent.append("\(route.sessionID)/\(route.agentID ?? "-")/\(route.toolUseID ?? "-")") }
        )
    }

    private func demoStore() async throws -> ReplicaStore {
        let store = try makePoolStore(.demo)
        let transport = InMemoryCloudTransport()
        try await DemoSeed.load(into: TestPhone.hub(over: transport, .demo), now: now)
        _ = try await ReplicaHydrator(transport: transport, store: store).hydrateOnce()
        return store
    }

    func testRequestsOnAppearAndEvery60s() async throws {
        let spy = Spy()
        let model = SessionChatViewModel(sessionID: 11, agentID: nil, store: try TestPhone.replica(), requester: requester(spy))
        model.appeared()
        try await poll({ spy.sent == ["11/-/-"] }, "no request on appear")
        spy.tick?.yield()
        try await poll({ spy.sent == ["11/-/-", "11/-/-"] }, "no repeat on the tick")
        model.disappeared()
    }

    func testRequestCarriesTheSubagentAndTheSessionRecord() async throws {
        let store = try makePoolStore()
        let outbox = ActionOutbox(transport: try TestPhone.transport(), store: store, deviceID: DemoSeed.device.deviceID)
        let requester = SessionChatRequester.sending(through: outbox, store: store)
        requester.start(sessionID: 11, agentID: "demo-1", toolUseID: "toolu_demo1")
        try await poll({ ((try? store.pendingActions()) ?? []).count == 1 }, "no action queued")
        requester.stop(sessionID: 11, agentID: "demo-1", toolUseID: "toolu_demo1")
        let action = try XCTUnwrap(store.pendingActions().first)
        XCTAssertEqual(action.action.kind, .sessionChatRequest)
        XCTAssertEqual(action.entityRecordName, "terminal_session-11")
        XCTAssertEqual(action.action.params["session_id"], .integer(11))
        XCTAssertEqual(action.action.params["subagent_id"], .string("demo-1"))
        XCTAssertEqual(action.action.params["tool_use_id"], .string("toolu_demo1"))
    }

    func testARequestStillQueuedIsNotQueuedAgain() async throws {
        let store = try makePoolStore()
        let outbox = ActionOutbox(transport: try TestPhone.transport(), store: store, deviceID: DemoSeed.device.deviceID)
        var ticker: AsyncStream<Void>.Continuation?
        let requester = SessionChatRequester.sending(through: outbox, store: store) { AsyncStream { ticker = $0 } }
        requester.start(sessionID: 11, agentID: nil)
        try await poll({ ((try? store.pendingActions()) ?? []).count == 1 }, "no action queued")
        ticker?.yield()
        ticker?.yield()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(try store.pendingActions().count, 1, "the repeats found their request still waiting")
        requester.stop(sessionID: 11, agentID: nil)
    }

    func testAStaleStopDoesNotKillTheSuccessor() async throws {
        for (first, second) in [(nil, "b"), ("b", nil)] as [(String?, String?)] {
            let spy = Spy()
            let requester = requester(spy)
            requester.start(sessionID: 11, agentID: first)
            requester.start(sessionID: 11, agentID: second)
            try await poll({ spy.sent.count == 2 }, "no requests")
            requester.stop(sessionID: 11, agentID: first)
            spy.tick?.yield()
            try await poll({ spy.sent.count == 3 }, "the stale stop killed the running loop")
            XCTAssertEqual(spy.sent.last, "11/\(second ?? "-")/-")
            requester.stop(sessionID: 11, agentID: second)
        }
    }

    func testReopeningAnExpiredChatAsksAgain() async throws {
        let spy = Spy()
        var releases: [CheckedContinuation<Void, Never>] = []
        let model = SessionChatViewModel(
            sessionID: 17, agentID: nil, store: try await demoStore(), requester: requester(spy),
            sleep: { _ in await withCheckedContinuation { releases.append($0) } } // swiftlint:disable:this trailing_closure
        )
        model.appeared()
        try await poll({ releases.count == 1 }, "the wait never began")
        releases[0].resume()
        try await poll({ model.waitingTooLong }, "never waited too long")
        model.disappeared()
        model.appeared()
        XCTAssertFalse(model.waitingTooLong, "back to Asking your Mac…")
        try await poll({ releases.count == 2 }, "the wait did not restart")
        model.disappeared()
        releases[1].resume()
    }

    func testStopsOnDisappear() async throws {
        let spy = Spy()
        let model = SessionChatViewModel(sessionID: 11, agentID: nil, store: try TestPhone.replica(), requester: requester(spy))
        model.appeared()
        try await poll({ spy.sent.count == 1 }, "no request on appear")
        model.disappeared()
        spy.tick?.yield()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(spy.sent.count, 1, "a tick after disappear sends nothing")
    }

    func testShowsAskingThenWaitingTooLong() async throws {
        let spy = Spy()
        var release: CheckedContinuation<Void, Never>?
        let model = SessionChatViewModel(
            sessionID: 17, agentID: nil, store: try await demoStore(), requester: requester(spy),
            sleep: { _ in await withCheckedContinuation { release = $0 } } // swiftlint:disable:this trailing_closure
        )
        model.appeared()
        try await poll({ release != nil }, "the wait never began")
        XCTAssertNil(model.chat, "no record for session 17")
        XCTAssertFalse(model.waitingTooLong, "Asking your Mac… until the limit")
        XCTAssertEqual(SessionChatText.asking, "Asking your Mac…")
        release?.resume()
        try await poll({ model.waitingTooLong }, "never waited too long")
        XCTAssertEqual(SessionChatText.tooLong, "Your Mac has not sent this chat yet. Is it awake?")
        model.disappeared()
    }

    func testTheDemoChatArrivesAndClearsTheWait() async throws {
        let model = SessionChatViewModel(
            sessionID: 11, agentID: nil, store: try await demoStore(), requester: requester(Spy()),
            sleep: { _ in } // swiftlint:disable:this trailing_closure
        )
        model.appeared()
        try await poll({ model.chat != nil }, "the demo chat never arrived")
        XCTAssertFalse(model.waitingTooLong)
        XCTAssertEqual(model.chat?.entries.map(\.kind.rawValue), ["owner", "agent", "ask_answer", "subagent", "agent"])
        model.disappeared()
    }

    func testSubagentRowPushesSubagentRoute() throws {
        let chat = try demoChat()
        let subagent = try XCTUnwrap(chat.entries.first { $0.kind == .subagent }?.subagent)
        let route = try XCTUnwrap(SessionChatEntryRow.route(for: subagent, sessionID: chat.sessionID))
        XCTAssertEqual(route, SessionChatRoute(sessionID: 11, agentID: "demo-1", toolUseID: "toolu_demo1"))
        XCTAssertEqual(SessionChat.recordName(sessionID: route.sessionID, agentID: route.agentID), "session_chat-11-demo-1")
        for (agent, tool) in [("", "toolu_demo1"), ("demo-1", ""), ("", "")] {
            let incomplete = SessionChat.Entry.Subagent(agentID: agent, toolUseID: tool, type: "Explore", description: "d", status: "running")
            XCTAssertNil(SessionChatEntryRow.route(for: incomplete, sessionID: 11), "no route without both ids")
        }
        XCTAssertEqual(SessionChatEntryRow.statusText("running"), "Running")
    }

    func testTheChatGoingAwayStartsThePatienceTimerAgain() async throws {
        let store = try await demoStore()
        var releases: [CheckedContinuation<Void, Never>] = []
        let model = SessionChatViewModel(
            sessionID: 11, agentID: nil, store: store, requester: requester(Spy()),
            sleep: { _ in await withCheckedContinuation { releases.append($0) } } // swiftlint:disable:this trailing_closure
        )
        model.appeared()
        try await poll({ model.chat != nil }, "the demo chat never arrived")
        XCTAssertFalse(model.waitingTooLong)
        let wireName = try await store.reader.read {
            try String.fetchOne($0, sql: "SELECT record_name FROM slice_records WHERE plain_name = 'session_chat-11'")
        }
        let batch = CloudChangeBatch(changed: [], deletedRecordNames: [try XCTUnwrap(wireName)], newToken: CloudChangeToken(value: Int.max / 2))
        XCTAssertTrue(try store.apply(batch))
        try await poll({ model.chat == nil }, "the chat stayed")
        try await poll({ !releases.isEmpty }, "no patience timer after the chat went away")
        releases.forEach { $0.resume() }
        try await poll({ model.waitingTooLong }, "never waited too long")
        model.disappeared()
    }

    func testSentLineKeepsItsBubbleUntilTheFeedShowsIt() async throws {
        let store = try await demoStore()
        var releases: [CheckedContinuation<Void, Never>] = []
        let model = SessionChatViewModel(
            sessionID: 11, agentID: nil, store: store, requester: requester(Spy()),
            sleep: { _ in await withCheckedContinuation { releases.append($0) } } // swiftlint:disable:this trailing_closure
        )
        model.appeared()
        try await poll({ model.chat != nil }, "the demo chat never arrived")
        let future = Date().addingTimeInterval(3_600) // after every demo entry
        let line = SessionChatViewModel.Outgoing(id: "a1", text: "Please also run the linter.", sentAt: future)
        model.noteOutgoing([line])
        XCTAssertTrue(model.sentLines.isEmpty, "still in the outbox: the pending bubble shows it")
        model.noteOutgoing([])
        XCTAssertEqual(model.sentLines.map(\.text), ["Please also run the linter."], "applied: the bubble stays")
        let entry = SessionChat.Entry(id: "x", kind: .owner, at: future.addingTimeInterval(5), text: "Please also run the linter.")
        let old = SessionChat.Entry(id: "y", kind: .owner, at: future.addingTimeInterval(-5), text: "Please also run the linter.")
        XCTAssertFalse(model.sentLines[0].isShown(in: SessionChat(sessionID: 11, live: true, entries: [old])), "an older identical line is not it")
        XCTAssertTrue(model.sentLines[0].isShown(in: SessionChat(sessionID: 11, live: true, entries: [entry])))
        try await poll({ releases.count == 2 }, "no 90 s timer next to the patience timer")
        releases.forEach { $0.resume() }
        try await poll({ model.sentLines.isEmpty }, "the bubble outlived 90 s")
        let failed = SessionChatViewModel.Outgoing(id: "a2", text: "x", sentAt: future, failed: true)
        model.noteOutgoing([failed])
        model.noteOutgoing([])
        XCTAssertTrue(model.sentLines.isEmpty, "a failed line that was dismissed leaves no bubble")
        model.disappeared()
    }

    func testEarlierMessagesLine() {
        XCTAssertNil(SessionChatViewModel.earlierText(0))
        XCTAssertEqual(SessionChatViewModel.earlierText(12), "12 earlier messages — open on the Mac")
        XCTAssertEqual(SessionChatViewModel.earlierText(1), "1 earlier message — open on the Mac")
    }

    // MARK: - The Tell bar rule is the session detail's

    private func inputModel(typing: Bool) throws -> SessionInputModel {
        var snapshot = try demoSnapshot(now: now)
        snapshot.heartbeat = HeartbeatPayload(
            updatedAt: now, appVersion: "1.0", hubID: "hub", macName: "Acme Mac", flavor: .default,
            lastPublishAt: now, lastRelayAt: now, relayBacklog: 0, accounts: [],
            enabledAt: now, ownerUser: "_user", sharing: .none
        )
        let session = try mirror(TerminalSessionState.self, DemoSeed.JSON.session(11, workbench: DemoSeed.acmeID, [:]))
        let grant = DeviceGrant(
            deviceID: DemoSeed.device.deviceID, hubID: "hub", name: "Demo iPhone", scope: .private, linked: true,
            typingAllowed: typing, startSessionsAllowed: true
        )
        return SessionInputModel(session: session, snapshot: snapshot, grant: grant, typingRequested: true, delivered: nil, now: now)
    }

    func testTellBarHiddenWithoutTypingGrant() throws {
        XCTAssertFalse(try inputModel(typing: false).showsBar)
    }

    func testTellBarShownWithTypingGrant() throws {
        XCTAssertTrue(try inputModel(typing: true).showsBar)
    }

    private func demoChat() throws -> SessionChat {
        try mirror(SessionChat.self, DemoSeed.sessionChatPayload(now: now))
    }
}
