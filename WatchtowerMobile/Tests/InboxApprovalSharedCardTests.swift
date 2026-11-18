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

    private func state(_ card: InboxCard, _ row: InboxRowState? = nil, grants: Grants = .all, away: Bool = false) -> ChatApprovalState {
        InboxApprovalState.make(card: card, rowState: row, grants: grants, hubAway: away, hubName: "Acme Mac", now: now)
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
        try await poll({ hub.requests.count == 1 }, "Retry queued")
        XCTAssertEqual(hub.requests.first?.target, "a103")
        XCTAssertEqual(hub.requests.first?.params.approvalVerb, .retry)
    }

    func testApproveAndRejectPinTheArgsAndRejectNeedsNoGrant() async throws {
        let hub = FakeInboxHub(feed: feed)
        let center = try await startedInboxCenter(hub)
        let (ungranted, action) = try services(center, DemoSeed.Inbox.slackProposal, grants: Grants(permissions: false, typing: false))
        ungranted.decide(action, .approve(patch: nil))
        ungranted.decide(action, .reject)
        try await poll({ hub.requests.count == 1 }, "Reject queued")
        XCTAssertEqual(hub.requests.map(\.params.approvalVerb), [.reject], "no Approve without the grant")
        let (granted, _) = try services(center, "a102")
        granted.decide(ChatAgentAction(inboxCard: try XCTUnwrap(center.feed?.cards.first { $0.id == "a102" })), .approve(patch: nil))
        try await poll({ hub.requests.count == 2 }, "Approve queued")
        XCTAssertEqual(hub.requests.last?.params.approvalVerb, .approve)
        XCTAssertEqual(hub.requests.last?.params.argsSHA256, "args-102")
    }

    func testNoDismissOnAnOrdinaryFailedRow() throws {
        let center = InboxCenter.detached()
        center.showForTour(feed: feed)
        let (services, action) = try services(center, "a103")
        XCTAssertNotEqual(AgentActionCard.settledRow(for: action, services: services, offersRetry: true,
                                                     state: services.state?(action)), .offer(.dismiss))
    }
}
