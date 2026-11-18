import ChatUI
import ChatWire
import SwiftUI
import WatchtowerInterface
@testable import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// A Needs approval entry as the shared card reads it (mobile Inbox spec §12.1).
final class ChatAgentActionInboxTests: XCTestCase {
    private func approval(args: String?, complete: Bool = true, external: Bool = true, tool: String = "send_slack_message") -> Approval {
        Approval(tool: tool, title: "Send a Slack message", summary: "Release 2.0 is out.", argsSHA256: "args-1", status: "pending",
                 error: "", proposer: "", reason: "From the release thread", editOnMac: false, target: "", targetNote: "",
                 targetUntil: "", superseded: false, disclosure: "", recipeText: "", diff: [], recipeClipped: false,
                 argsDisplay: args, argsComplete: args == nil ? nil : complete, external: external)
    }

    private func card(_ approval: Approval, id: String = "a101") -> InboxCard {
        var card = DemoSeed.Inbox.approvalCards(now: Date())[0]
        card.id = id
        card.approval = approval
        return card
    }

    func testTheActionComesFromTheFeedsApproval() {
        let action = ChatAgentAction(inboxCard: card(approval(args: #"{"text": "hi"}"#)))
        XCTAssertEqual(action.id, 101)
        XCTAssertEqual(action.tool, "send_slack_message")
        XCTAssertEqual(action.argsJSON, #"{"text": "hi"}"#)
        XCTAssertFalse(action.argsStored, "display text, never hashed")
        XCTAssertEqual(action.approveDigest, "args-1", "Approve pins the feed's digest (AGENT-07)")
        XCTAssertTrue(action.argsComplete)
        XCTAssertTrue(action.external)
        XCTAssertEqual(action.reason, "From the release thread")
        XCTAssertNil(InboxApprovalState.summary(card(approval(args: "{}"))), "the per-tool body stays")
    }

    func testNoArgsDisplayFallsBackToTheSummary() {
        let older = card(approval(args: nil))
        let action = ChatAgentAction(inboxCard: older)
        XCTAssertEqual(action.argsJSON, "")
        XCTAssertFalse(action.argsComplete)
        XCTAssertEqual(InboxApprovalState.summary(older), "“Release 2.0 is out.”")
    }

    func testARecipeDraftKeepsTheFeedsTitleAndSummary() {
        let draft = card(approval(args: #"{"name": "x"}"#, tool: "save_automation"))
        XCTAssertEqual(InboxApprovalState.title(draft), "Send a Slack message")
        XCTAssertEqual(InboxApprovalState.summary(draft), "“Release 2.0 is out.”")
        XCTAssertNil(InboxApprovalState.title(card(approval(args: "{}"))), "the shared catalog names every other tool")
    }
}

/// The decision row's state on a Needs approval entry, one case per state of §12.5.
@MainActor
final class InboxApprovalStateTests: XCTestCase {
    private let now = Date()
    private var feed: Feed { DemoSeed.Inbox.feed(now: now) }
    /// The seed's pending Slack send (a101) and its failed Linear issue (a103).
    private var pending: InboxCard { DemoSeed.Inbox.approvalCards(now: now)[0] }
    private var failed: InboxCard { DemoSeed.Inbox.approvalCards(now: now)[2] }

    private func state(
        _ card: InboxCard,
        _ row: InboxRowState? = nil,
        grants: Grants = .all,
        away: Bool = false,
        host: TowerHost = .mac
    ) -> ChatApprovalState {
        InboxApprovalState.make(card: card, rowState: row, grants: grants, hubAway: away, hubName: "Acme Mac", now: now, host: host)
    }

    private func request(_ verb: ApprovalVerb) -> ActRequest {
        ActRequest(requestID: "r", target: "a101", verb: .approval, params: ActParams(approvalVerb: verb, argsSHA256: "args-101"))
    }

    func testPendingWithTheGrantIsLive() {
        let s = state(pending)
        XCTAssertTrue(s.showsButtons && s.canAnswer)
        XCTAssertNil(s.approveNote)
        XCTAssertNil(s.line)
    }

    func testWithoutTheGrantApproveIsANoteAndRejectStaysLive() {
        let s = state(pending, grants: Grants(permissions: false, typing: true))
        XCTAssertEqual(s.approveNote, "Approve on the Mac")
        XCTAssertTrue(s.canAnswer, "Reject needs no grant")
        XCTAssertEqual(AgentActionCard.availability(s), .live)
    }

    func testFailedWithoutTheGrantSaysRetryOnTheMac() {
        XCTAssertNil(state(failed).settledNote)
        XCTAssertEqual(state(failed, grants: Grants(permissions: false, typing: true)).settledNote, "Retry on the Mac")
    }

    func testBusyLinesNameThePress() {
        for (verb, line) in [(ApprovalVerb.approve, "Approving…"), (.reject, "Rejecting…"), (.retry, "Retrying…"), (.dismiss, "Dismissing…")] {
            let s = state(pending, .busy(request(verb)))
            XCTAssertEqual(s.line, line)
            XCTAssertTrue(s.inFlight)
            XCTAssertFalse(s.canAnswer)
        }
    }

    func testWaitingToSendWhileTheHubIsAway() {
        let s = state(pending, .busy(request(.approve)), away: true)
        XCTAssertEqual(s.line, "Waiting to send — it applies when Acme Mac wakes.")
        XCTAssertFalse(s.canAnswer)
        XCTAssertFalse(s.inFlight)
    }

    func testARefusalShowsTheSentenceAndTheRowIsLiveAgain() {
        let sentence = "This proposal changed on the Mac — look again before approving."
        let s = state(pending, .refused(sentence, .resend(request(.approve), dismiss: nil)))
        XCTAssertEqual(s.gestureError, sentence)
        XCTAssertTrue(s.canAnswer)
        XCTAssertNil(s.undelivered)
    }

    func testNotDeliveredIsItsNamedRetryAlone() {
        let line = "Not delivered — Acme Mac didn't get it."
        let s = state(pending, .refused(line, .outbox(actionID: "act-1", request(.approve))))
        XCTAssertEqual(s.undelivered?.line, line)
        XCTAssertEqual(s.undelivered?.retryTitle, "Retry Approve")
    }

    func testDidntConfirmTurnsTheRowOff() {
        let s = state(pending, .unknown)
        XCTAssertEqual(s.line, "Didn't confirm — check on the Mac.")
        XCTAssertFalse(s.canAnswer)
    }

    /// On a server tower every note names the tower (§12.3); a recipe draft still opens on the Mac.
    func testOnAServerTowerTheNotesNameTheTower() {
        let tower = TowerHost.server(device: nil)
        let noGrant = Grants(permissions: false, typing: true)
        XCTAssertEqual(state(pending, grants: noGrant, host: tower).approveNote, "Approve on your tower")
        XCTAssertEqual(state(failed, grants: noGrant, host: tower).settledNote, "Retry on your tower")
        XCTAssertEqual(state(pending, grants: noGrant).approveNote, "Approve on the Mac")
        var draft = pending
        draft.approval?.tool = "save_automation"
        XCTAssertEqual(state(draft, grants: noGrant, host: tower).approveNote, "Open Draft — on your Mac")
    }

    /// Every refusal the tower words (inboxfeed.Sentence) shows as it came, and the row is live again.
    func testEveryRefusalSentenceShows() {
        for sentence in [
            "Couldn't approve it: this card changed — look again.",
            "This proposal changed on the Mac — look again before approving.",
            "Couldn't approve it: edit this proposal on the Mac.",
            "Couldn't dismiss it: this card doesn't offer that here."
        ] {
            let s = state(pending, .refused(sentence, .resend(request(.approve), dismiss: nil)))
            XCTAssertEqual(s.gestureError, sentence)
            XCTAssertTrue(s.canAnswer)
        }
    }

    /// A pending (or approved, running) connector call in Needs approval is held by its live chat session.
    func testAConnectorCallInNeedsApprovalIsHeld() {
        for status in ["pending", "approved", "executing"] {
            XCTAssertTrue(InboxApprovalState.sessionHolds(ChatAgentAction(id: 1, tool: ConnectorCallProposal.tool, status: status)))
        }
        XCTAssertFalse(InboxApprovalState.sessionHolds(ChatAgentAction(id: 1, tool: ConnectorCallProposal.tool, status: "failed")))
    }

    /// A Slack draft whose workspace is not chosen, its display args clipped past reading: the hub's
    /// `needs_workspace` keeps Approve off, with where to choose; Reject stays live.
    func testAClippedSlackDraftWithoutItsWorkspaceOffersNoApprove() {
        var draft = pending
        draft.approval?.argsDisplay = "{\n  \"text\": \"日本語日本語"
        draft.approval?.argsComplete = false
        draft.approval?.needsWorkspace = true
        let s = state(draft)
        XCTAssertEqual(s.approveNote, "Choose a workspace on Acme Mac before approving")
        XCTAssertTrue(s.canAnswer, "Reject stays live")
        XCTAssertNil(state(pending).approveNote)
    }

    func testARecipeDraftOpensOnTheMac() {
        var draft = pending
        draft.approval?.tool = "save_automation"
        XCTAssertEqual(state(draft).approveNote, "Open Draft — on your Mac")
    }
}

/// The shared card's services on a Needs approval entry send `inbox.act` `approval` presses (§12.3).
@MainActor
final class InboxApprovalServicesTests: XCTestCase {
    private let now = Date()
    private var feed: Feed { DemoSeed.Inbox.feed(now: now) }

    private func services(_ center: InboxCenter, _ id: String, grants: Grants = .all) throws -> (ChatApprovalServices, ChatAgentAction) {
        let card = try XCTUnwrap(center.feed?.cards.first { $0.id == id })
        return (InboxApprovalCard.services(center: center, card: card, grants: grants, hubAway: false, hubName: "Acme Mac", now: now),
                ChatAgentAction(inboxCard: card))
    }

    func testRetrySendsApprovalRetry() async throws {
        let hub = FakeInboxHub(feed: feed)
        let center = try await startedInboxCenter(hub)
        let (services, action) = try services(center, "a103")
        XCTAssertEqual(AgentActionCard.settledOffer(for: action), .retry)
        services.retry?(action)
        try await pollBounded({ hub.requests.count == 1 }, "Retry queued")
        XCTAssertEqual(hub.requests.first?.target, "a103")
        XCTAssertEqual(hub.requests.first?.params.approvalVerb, .retry)
    }

    func testApproveAndRejectPinTheArgsAndRejectNeedsNoGrant() async throws {
        let hub = FakeInboxHub(feed: feed)
        let center = try await startedInboxCenter(hub)
        let (ungranted, action) = try services(center, DemoSeed.Inbox.slackProposal, grants: Grants(permissions: false, typing: false))
        ungranted.decide(action, .approve(patch: nil))
        ungranted.decide(action, .reject)
        try await pollBounded({ hub.requests.count == 1 }, "Reject queued")
        XCTAssertEqual(hub.requests.map(\.params.approvalVerb), [.reject], "no Approve without the grant")
        let (granted, _) = try services(center, "a102")
        granted.decide(ChatAgentAction(inboxCard: try XCTUnwrap(center.feed?.cards.first { $0.id == "a102" })), .approve(patch: nil))
        try await pollBounded({ hub.requests.count == 2 }, "Approve queued")
        XCTAssertEqual(hub.requests.last?.params.approvalVerb, .approve)
        XCTAssertEqual(hub.requests.last?.params.argsSHA256, "args-102")
    }

    /// A pending claude.ai connector call reads "Awaiting your approval" and offers Approve with the grant, as the old
    /// card did — never "Chat session ended" on a live call (#1006 review I1).
    func testAPendingConnectorCallOffersApprove() async throws {
        var seeded = feed
        let index = try XCTUnwrap(seeded.cards.firstIndex { $0.id == DemoSeed.Inbox.replyProposal })
        seeded.cards[index].approval = DemoSeed.Inbox.approval(
            ConnectorCallProposal.tool, "Run a connector", "Linear", "args-102",
            args: #"{"server": "Linear", "tool": "create_issue", "input": {"title": "x"}}"#)
        let hub = FakeInboxHub(feed: seeded)
        let center = try await startedInboxCenter(hub)
        let (services, action) = try services(center, DemoSeed.Inbox.replyProposal)
        let holds = services.sessionHoldsCall?(action) ?? false
        XCTAssertTrue(holds)
        XCTAssertEqual(ConnectorCallProposal.statusLabel(for: action, sessionHolds: holds), "Awaiting your approval")
        XCTAssertTrue(ConnectorCallProposal.canApprove(action, sessionHolds: holds))
        services.decide(action, .approve(patch: nil))
        try await pollBounded({ hub.requests.count == 1 }, "Approve queued")
        XCTAssertEqual(hub.requests.first?.params.approvalVerb, .approve)
    }

    /// Retry follows the card's rule: never on an older button proposal or without the grant.
    func testRetryFollowsTheCardsRule() throws {
        var failed = try XCTUnwrap(feed.cards.first { $0.id == "a103" })
        XCTAssertTrue(InboxApprovalState.mayRetry(failed, grants: .all))
        XCTAssertFalse(InboxApprovalState.mayRetry(failed, grants: Grants(permissions: false, typing: true)))
        failed.approval?.superseded = true
        XCTAssertFalse(InboxApprovalState.mayRetry(failed, grants: .all))
        let pending = try XCTUnwrap(feed.cards.first { $0.id == DemoSeed.Inbox.slackProposal })
        XCTAssertFalse(InboxApprovalState.mayRetry(pending, grants: .all))
    }

    /// The tab's inputs reach the card: with the Mac away a press reads "Waiting to send" (§12.6).
    func testTheHubAwayReachesTheCardAsWaitingToSend() async throws {
        let hub = FakeInboxHub(feed: feed)
        let center = try await startedInboxCenter(hub)
        let card = try XCTUnwrap(center.feed?.cards.first { $0.id == DemoSeed.Inbox.slackProposal })
        let model = InboxCardModel(card: card, platform: .phone, grants: .all, blocksReadable: true, now: now, hidden: center.hidden)
        let inputs = InboxInputs(capability: "on", hubName: "Acme Mac", macAway: now, grants: .all, now: now, host: .mac)
        let view = InboxApprovalCard(center: center, card: model, inputs: inputs)
        XCTAssertTrue(view.hubAway)
        let services = InboxApprovalCard.services(center: center, card: card, grants: view.grants, hubAway: view.hubAway,
                                                  hubName: view.hubName, now: now, host: view.host)
        let action = ChatAgentAction(inboxCard: card)
        services.decide(action, .approve(patch: nil))
        try await pollBounded({ hub.requests.count == 1 }, "Approve queued")
        XCTAssertEqual(services.state?(action)?.line, "Waiting to send — it applies when Acme Mac wakes.")
    }

    /// A Not delivered approve from the replica: its named Retry alone, which re-sends the same outbox action, and it
    /// wins over the target row (§12.4, §12.6).
    func testNotDeliveredFromTheReplicaResendsTheSameAction() async throws {
        let hub = FakeInboxHub(feed: feed)
        let center = try await startedInboxCenter(hub)
        var retried: [String] = []
        center.use(dismiss: { _ in }, retryUndelivered: { retried.append($0) })
        let approve = ActRequest(requestID: "first", target: DemoSeed.Inbox.slackProposal, verb: .approval,
                                 params: ActParams(approvalVerb: .approve, argsSHA256: "args-101"))
        center.receive(InboxReplicaSnapshot(actions: [
            try FakeInboxHub.failedRow(approve, id: "act-undelivered", reason: nil, message: nil, undelivered: true)
        ]))
        let (services, action) = try services(center, DemoSeed.Inbox.slackProposal)
        let state = try XCTUnwrap(services.state?(action))
        XCTAssertEqual(state.undelivered?.line, InboxPhoneText.notDelivered(hub: ""))
        XCTAssertEqual(state.undelivered?.retryTitle, "Retry Approve")
        XCTAssertEqual(AgentActionCard.decisionRowKind(for: action, state: state, hasOverride: true), .undelivered)
        services.resend?(action)
        try await pollBounded({ retried.count == 1 }, "the named Retry re-sent the action")
        XCTAssertEqual(retried, ["act-undelivered"])
        XCTAssertTrue(hub.requests.isEmpty, "no new press")
    }

    /// An `already` answer hides the card like `ok` (§12.5), also when it lands with no press waiting.
    func testAnAlreadyAnswerHidesTheCard() async throws {
        let hub = FakeInboxHub(feed: feed)
        let center = try await startedInboxCenter(hub)
        let approve = ActRequest(requestID: "late", target: DemoSeed.Inbox.slackProposal, verb: .approval,
                                 params: ActParams(approvalVerb: .approve, argsSHA256: "args-101"))
        var echo = ActionRequestPayload(id: "act-late", kind: .inboxAct, entityID: nil, params: try HubTransport.wireParams(approve),
                                        createdAt: now, deviceID: "phone")
        echo.status = .applied
        echo.result = ["already": .bool(true), "status": .string("applied")]
        center.receiveApplied(echo)
        XCTAssertTrue(center.hidden.isHidden(DemoSeed.Inbox.slackProposal))
    }

    func testNoDismissOnAnOrdinaryFailedRow() throws {
        let center = InboxCenter.detached()
        center.showForTour(feed: feed)
        let (services, action) = try services(center, "a103")
        XCTAssertNotEqual(AgentActionCard.settledRow(for: action, services: services, offersRetry: true,
                                                     state: services.state?(action)), .offer(.dismiss))
    }
}
