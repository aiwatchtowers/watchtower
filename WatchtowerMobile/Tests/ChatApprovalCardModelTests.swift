import ChatUI
import ChatWire
import WatchtowerKit
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// The phone chat's Retry and Dismiss (mobile Inbox spec §12.9, ask #1553): the card's own rule, the grant and the
/// hub's `chat_actions` decide what shows; a press on its way, a refusal, `outcome_unknown` and an `already` answer
/// each read as the spec's state table says.
@MainActor
final class ChatApprovalCardModelTests: XCTestCase {
    static let unknown = ConnectorCallProposal.sessionEndedWhileRunning
    static let failed = ChatFeed.Action(id: 41, tool: "create_jira_issue", title: "Create a Jira issue", argsDisplay: "{}",
                                        argsSHA256: "b2", status: "failed", external: true, error: "jira: 503")
    static let outcomeUnknown = ChatFeed.Action(id: 42, tool: ConnectorCallProposal.tool, title: "Run a connector",
                                                argsDisplay: "{}", argsSHA256: "d4", status: "failed", error: unknown)

    private func card(
        _ action: ChatFeed.Action,
        permissions: Bool = true,
        online: Bool = true,
        inFlight: Bool = false,
        failure: ChatActionFailure? = nil,
        retryDismiss: Bool = true
    ) -> ChatApprovalCardModel {
        ChatApprovalCardModel(payload: ChatApprovalPayload(action: action), permissions: permissions, online: online,
                              inFlight: inFlight, failure: failure, host: .mac, retryDismiss: retryDismiss)
    }

    private func row(_ model: ChatApprovalCardModel, retry: Bool = true) -> AgentActionCard.SettledRow {
        let services = ChatApprovalServices(retry: { _ in }, dismiss: { _ in })
        return AgentActionCard.settledRow(for: ChatAgentAction(payload: model.payload), services: services,
                                          offersRetry: retry, state: model.state)
    }

    func testFailedOffersRetryWithTheGrantAndTheCapability() {
        let model = card(Self.failed)
        XCTAssertEqual(model.settledOffer, .retry)
        XCTAssertNil(model.settledNote)
        XCTAssertTrue(model.state.canAnswer)
        XCTAssertEqual(row(model), .offer(.retry))
        XCTAssertNil(model.state.line)
    }

    func testWithoutTheGrantOrTheCapabilityTheCardSaysWhere() {
        XCTAssertEqual(row(card(Self.failed, permissions: false)), .note("Retry on the Mac"))
        XCTAssertEqual(row(card(Self.failed, retryDismiss: false)), .note("Retry on the Mac"), "an older hub")
        XCTAssertEqual(row(card(Self.outcomeUnknown, permissions: false)), .note("Dismiss on the Mac"))
        let tower = ChatApprovalCardModel(payload: ChatApprovalPayload(action: Self.failed), permissions: false, online: true,
                                          inFlight: false, failure: nil, host: .server(device: nil), retryDismiss: true)
        XCTAssertEqual(tower.settledNote, "Retry on your tower")
        XCTAssertNil(card(Self.failed, permissions: false).state.line, "the outcome line does not repeat under the note")
    }

    func testOutcomeUnknownOffersDismissAndADismissedOneDoesNot() {
        XCTAssertEqual(row(card(Self.outcomeUnknown)), .offer(.dismiss))
        let dismissed = ChatFeed.Action(id: 42, tool: ConnectorCallProposal.tool, title: "", argsDisplay: "{}", argsSHA256: "d4",
                                        status: "failed", error: Self.unknown, dismissedAt: "2026-11-18T09:00:00Z")
        XCTAssertEqual(card(dismissed).settledOffer, .none)
        XCTAssertEqual(row(card(dismissed)), .none)
    }

    func testOnItsWayTheButtonIsOffWithTheSendingLine() {
        let model = card(Self.failed, inFlight: true)
        XCTAssertFalse(model.state.canAnswer)
        XCTAssertTrue(model.state.inFlight)
        XCTAssertEqual(model.state.line, ChatApprovalCardModel.sendingLine)
    }

    func testTheHubAwayTurnsTheButtonOffAndQueuesNothing() {
        let model = card(Self.failed, online: false)
        XCTAssertFalse(model.state.canAnswer)
        XCTAssertNil(model.state.line)
        XCTAssertEqual(AgentActionCard.availability(model.state), .disabled)
    }

    func testARefusalShowsTheHubsSentenceInRed() {
        let model = card(Self.failed, failure: ChatActionFailure(reason: .notPending, message: "Already approved"))
        XCTAssertEqual(model.state.gestureError, "Already approved")
        XCTAssertTrue(model.state.canAnswer)
        XCTAssertEqual(card(Self.failed, failure: ChatActionFailure(reason: nil, message: "")).state.gestureError,
                       ChatSendCoordinator.couldNotSend)
        XCTAssertEqual(card(Self.failed, failure: ChatActionFailure(reason: .changed, message: "x")).state.gestureError,
                       ChatApprovalCardModel.changedLine)
    }

    func testDidntConfirmKeepsTheButtonOff() {
        let model = card(Self.failed, failure: ChatActionFailure(reason: .outcomeUnknown, message: ""))
        XCTAssertFalse(model.state.canAnswer)
        XCTAssertEqual(model.state.line, "Didn't confirm — check on the Mac.")
        XCTAssertNil(model.state.gestureError)
    }

    func testOnAServerTowerTheLinesNameTheTower() {
        let tower = ChatApprovalCardModel(payload: ChatApprovalPayload(action: Self.outcomeUnknown), permissions: false,
                                          online: true, inFlight: false, failure: nil, host: .server(device: nil), retryDismiss: true)
        XCTAssertEqual(tower.settledNote, "Dismiss on your tower")
        let unconfirmed = ChatApprovalCardModel(
            payload: ChatApprovalPayload(action: Self.failed), permissions: true, online: true, inFlight: false,
            failure: ChatActionFailure(reason: .outcomeUnknown, message: ""), host: .server(device: nil), retryDismiss: true)
        XCTAssertEqual(unconfirmed.state.line, "Didn't confirm — check on your tower.")
    }

    func testAPendingActionKeepsTodaysLook() {
        let pending = ChatFeed.Action(id: 31, tool: "send_slack_message", title: "", argsDisplay: "", argsSHA256: "abc123",
                                      status: "pending")
        let state = card(pending).state
        XCTAssertNil(state.settledNote)
        XCTAssertNil(state.gestureError)
        XCTAssertFalse(state.inFlight)
        XCTAssertEqual(card(pending, permissions: false).state.line, "Approve on the Mac")
    }
}

/// The phone chat's approval services send Retry and Dismiss as `chat_action_answer` (§12.9) — once, only to a hub
/// that takes them, never while it is away.
@MainActor
final class ChatConversationApprovalTests: XCTestCase {
    private var sleeper: TickSleeper!
    private var recorder: RecordingChatSender!
    private var center: ChatsCenter!

    override func setUp() async throws {
        sleeper = TickSleeper()
        recorder = RecordingChatSender()
        center = ChatFixture.center(recorder, sleeper: sleeper)
        var snapshot = center.snapshot
        snapshot.feeds[7] = ChatFixture.entry(ChatFixture.feed(
            messages: [ChatFixture.message(1, "user")],
            actions: [ChatApprovalCardModelTests.failed, ChatApprovalCardModelTests.outcomeUnknown]
        ))
        center.apply(snapshot)
        center.setGate(ChatsGateModel(ChatFixture.inputs()))
    }

    override func tearDown() async throws {
        sleeper.cancelAll()
    }

    private func services(retryDismiss: Bool, permissions: Bool = true) -> ChatApprovalServices {
        ChatConversationView.approvals(client: center.client, permissions: permissions, host: .mac, retryDismiss: retryDismiss,
                                       runningTurnID: nil)
    }

    func testRetryAndDismissWired() async throws {
        let wired = services(retryDismiss: true)
        wired.retry?(ChatAgentAction(payload: ChatApprovalPayload(action: ChatApprovalCardModelTests.failed)))
        try await pollBounded({ (try? self.recorder.params(ChatActionAnswerParams.self).count) == 1 }, "retry sent")
        wired.dismiss?(ChatAgentAction(payload: ChatApprovalPayload(action: ChatApprovalCardModelTests.outcomeUnknown)))
        try await pollBounded({ (try? self.recorder.params(ChatActionAnswerParams.self).count) == 2 }, "dismiss sent")
        XCTAssertEqual(try recorder.params(ChatActionAnswerParams.self).map(\.decision), [.retry, .dismiss])
        XCTAssertEqual(try recorder.params(ChatActionAnswerParams.self).map(\.actionID), [41, 42])
    }

    private func echo(_ index: Int, result: [String: JSONValue]) -> ActionRequestPayload {
        var echo = ActionRequestPayload(id: RecordingChatSender.actionID(index), kind: .chatActionAnswer, entityID: nil,
                                        createdAt: ChatFixture.now)
        echo.status = .applied
        echo.result = result
        return echo
    }

    /// A repeated Dismiss answers `already` (applied, no write): the card shows no error (§12.9).
    func testAlreadyDismissedShowsNoError() async throws {
        let unknown = ChatAgentAction(payload: ChatApprovalPayload(action: ChatApprovalCardModelTests.outcomeUnknown))
        let answer = Task { await center.client.decide(unknown, .dismiss, permissions: true, retryDismiss: true) }
        try await pollBounded({ (try? self.recorder.params(ChatActionAnswerParams.self).count) == 1 }, "dismiss sent")
        center.receiveApplied(echo(1, result: ["status": .string("failed"), "dismissed": .bool(true), "already": .bool(true)]))
        await answer.value
        let model = center.client.approvalCard(unknown, permissions: true, host: .mac, retryDismiss: true)
        XCTAssertNil(model.refusal)
        XCTAssertNil(model.state.gestureError)
        XCTAssertNil(model.state.line)
    }

    /// "Didn't confirm" holds until the feed moves: the same action as when the answer went keeps the button off; a
    /// new state of it (another error, a dismissal) clears the line and offers what it offers now (§12.9).
    func testDidntConfirmClearsWhenTheFeedMoves() async throws {
        let failed = ChatAgentAction(payload: ChatApprovalPayload(action: ChatApprovalCardModelTests.failed))
        let answer = Task { await center.client.decide(failed, .retry, permissions: true, retryDismiss: true) }
        try await pollBounded({ (try? self.recorder.params(ChatActionAnswerParams.self).count) == 1 }, "retry sent")
        var snapshot = center.snapshot
        snapshot.failures = [RecordingChatSender.actionID(1): ChatActionFailure(reason: .outcomeUnknown, message: "")]
        center.apply(snapshot)
        await answer.value
        let held = center.client.approvalCard(failed, permissions: true, host: .mac, retryDismiss: true)
        XCTAssertEqual(held.state.line, "Didn't confirm — check on the Mac.")
        XCTAssertFalse(held.state.canAnswer)
        let moved = ChatAgentAction(payload: ChatApprovalPayload(action: ChatFeed.Action(
            id: 41, tool: "create_jira_issue", title: "", argsDisplay: "{}", argsSHA256: "b2", status: "failed", external: true,
            error: "jira: 502 Bad Gateway")))
        let fresh = center.client.approvalCard(moved, permissions: true, host: .mac, retryDismiss: true)
        XCTAssertNil(fresh.state.line)
        XCTAssertTrue(fresh.state.canAnswer)
    }

    /// A feed that moves (the retry runs) and comes back to the same failed status and error is a new state: the
    /// stored "Didn't confirm" is gone for good and Retry is live (§12.9).
    func testDidntConfirmDoesNotComeBackWhenTheFeedReturnsToTheSameState() async throws {
        let failedAction = ChatApprovalCardModelTests.failed
        let failed = ChatAgentAction(payload: ChatApprovalPayload(action: failedAction))
        let answer = Task { await center.client.decide(failed, .retry, permissions: true, retryDismiss: true) }
        try await pollBounded({ (try? self.recorder.params(ChatActionAnswerParams.self).count) == 1 }, "retry sent")
        var snapshot = center.snapshot
        snapshot.failures = [RecordingChatSender.actionID(1): ChatActionFailure(reason: .outcomeUnknown, message: "")]
        center.apply(snapshot)
        await answer.value
        XCTAssertEqual(center.client.approvalCard(failed, permissions: true, host: .mac, retryDismiss: true).state.line,
                       "Didn't confirm — check on the Mac.")

        let executing = ChatFeed.Action(id: 41, tool: "create_jira_issue", title: "", argsDisplay: "{}", argsSHA256: "b2",
                                        status: "executing", external: true)
        func show(_ action: ChatFeed.Action) {
            var next = center.snapshot
            next.feeds[7] = ChatFixture.entry(ChatFixture.feed(messages: [ChatFixture.message(1, "user")], actions: [action]))
            center.apply(next)
        }
        show(executing)
        show(failedAction)
        let back = center.client.approvalCard(failed, permissions: true, host: .mac, retryDismiss: true)
        XCTAssertNil(back.state.line)
        XCTAssertTrue(back.state.canAnswer)
    }

    func testNothingGoesWithoutTheCapabilityOrTheGrantOrToTheWrongRow() async throws {
        let failed = ChatAgentAction(payload: ChatApprovalPayload(action: ChatApprovalCardModelTests.failed))
        let unknown = ChatAgentAction(payload: ChatApprovalPayload(action: ChatApprovalCardModelTests.outcomeUnknown))
        await center.client.decide(failed, .retry, permissions: true, retryDismiss: false)
        await center.client.decide(failed, .retry, permissions: false, retryDismiss: true)
        await center.client.decide(failed, .dismiss, permissions: true, retryDismiss: true)
        await center.client.decide(unknown, .retry, permissions: true, retryDismiss: true)
        XCTAssertTrue(recorder.sent.isEmpty)
        XCTAssertEqual(services(retryDismiss: false).state?(failed)?.settledNote, "Retry on the Mac")
    }
}
