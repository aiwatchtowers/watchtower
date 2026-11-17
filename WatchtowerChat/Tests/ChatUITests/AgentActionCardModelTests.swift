import ChatWire
import SwiftUI
import XCTest
@testable import ChatUI

/// The shared approval card's rules (unified chat T15, ask #1409), pure: what the card draws and offers on each device
/// for the state and the capabilities the screen injects.
final class AgentActionCardModelTests: XCTestCase {
    private static let slackArgs = ##"{"text":"hi","target":{"account_id":3,"workspace":"acme","channel_id":"C1","label":"#general"}}"##
    private static let connectorArgs = #"{"server":"Linear","tool":"create_issue","input":{"title":"x"}}"#

    private func payload(
        tool: String,
        args: String,
        status: String = "pending",
        sha: String = "abc",
        complete: Bool = true,
        turn: String = "t1"
    ) -> ChatApprovalPayload {
        ChatApprovalPayload(id: 9, tool: tool, title: "", argsDisplay: args, argsSHA256: sha, status: status,
                            turnID: turn, argsComplete: complete)
    }

    private func action(
        tool: String = "create_target",
        args: String = #"{"text":"Call"}"#,
        status: String = "pending",
        complete: Bool = true,
        error: String = ""
    ) -> ChatAgentAction {
        ChatAgentAction(id: 9, tool: tool, external: true, argsJSON: args, argsComplete: complete, turnID: "t1",
                        status: status, error: error)
    }

    // MARK: - The phone's states (P1–P5)

    /// Offline (or an answer on its way): the buttons stay, off, and the card's body does not change.
    func testApprovalOfflineDisablesButtonsKeepsCard() {
        let offline = ChatApprovalState(showsButtons: true, canAnswer: false, line: "Offline")
        XCTAssertEqual(AgentActionCard.availability(offline), .disabled)
        XCTAssertEqual(AgentActionCard.availability(nil), .live)
        XCTAssertEqual(AgentActionCard.availability(ChatApprovalState(showsButtons: false, canAnswer: false, line: "x")),
                       .hidden)
        XCTAssertEqual(AgentActionCard.availability(ChatApprovalState(showsButtons: true, canAnswer: true, line: nil,
                                                                      inFlight: true)), .disabled)
        let card = ChatAgentAction(payload: payload(tool: "create_target", args: #"{"text":"Call"}"#))
        XCTAssertEqual(AgentActionCard.summaryLines(for: card), ["Call"], "the body is the same online or off")
        XCTAssertEqual(AgentActionCard.pendingApproval(for: card, editsSlack: false), .plain)
    }

    /// Args that reached the phone clipped: no Slack editor, no Confluence diff, no Edit Input — the "too long" line
    /// instead — and Approve still pins the payload's digest.
    func testClippedArgsHideEditorsAndDiff() {
        let editing = ChatApprovalServices(approveEdited: true)
        let clippedSlack = ChatAgentAction(payload: payload(tool: SlackSendProposal.tool, args: "{\"text\":\"hi", complete: false))
        XCTAssertFalse(AgentActionCard.editsSlack(clippedSlack, services: editing))
        XCTAssertEqual(AgentActionCard.summaryLines(for: clippedSlack), [SlackSendProposal.clippedNote])
        // Whole args marked incomplete parse, but are still not edited.
        let incomplete = ChatAgentAction(payload: payload(tool: SlackSendProposal.tool, args: Self.slackArgs, complete: false))
        XCTAssertFalse(AgentActionCard.editsSlack(incomplete, services: editing))
        XCTAssertNil(AgentActionCard.confluenceEdit(for: ChatAgentAction(payload: payload(
            tool: ConfluenceEdit.tool, args: #"{"title":"T","changes":[{"before":"a","after":"b"}]}"#, complete: false))))
        let connector = ChatAgentAction(payload: payload(tool: ConnectorCallProposal.tool, args: "{\"server\":", complete: false))
        XCTAssertFalse(AgentActionCard.connectorEditable(connector, services: editing, sessionHolds: true))
        XCTAssertEqual(connector.approveDigest, "abc", "Approve pins the digest Go stored")
        let whole = ChatAgentAction(payload: payload(tool: SlackSendProposal.tool, args: Self.slackArgs))
        XCTAssertTrue(AgentActionCard.editsSlack(whole, services: editing))
    }

    /// The card hands the screen the exact action it was built with: its args and its digest (AGENT-07).
    func testApproveCarriesTheShownSnapshot() {
        var answers: [(ChatAgentAction, ChatApprovalAnswer)] = []
        var services = ChatApprovalServices()
        services.decide = { answers.append(($0, $1)) }
        let shown = ChatAgentAction(payload: payload(tool: "create_target", args: #"{"text":"Call"}"#, sha: "d1g"))
        AgentActionCard.approve(shown, patch: nil, services: services)
        AgentActionCard.approve(shown, patch: #"{"text":"edited"}"#, services: services)
        XCTAssertEqual(answers.map(\.0), [shown, shown])
        XCTAssertEqual(answers.map(\.0.argsJSON), [#"{"text":"Call"}"#, #"{"text":"Call"}"#])
        XCTAssertEqual(answers.map(\.0.argsSHA256), ["d1g", "d1g"])
        XCTAssertEqual(answers.map(\.1), [.approve(patch: nil), .approve(patch: #"{"text":"edited"}"#)])
        // A payload with no digest offers no Approve: display text is never hashed.
        let undigested = ChatAgentAction(payload: payload(tool: "create_target", args: #"{"text":"Call"}"#, sha: ""))
        XCTAssertNil(undigested.approveDigest)
        XCTAssertEqual(AgentActionCard.pendingApproval(for: undigested, editsSlack: false), .none)
    }

    /// A capability the screen does not inject hides its control, on a row that would offer each (ask #1411).
    func testNilCapabilityHidesItsControl() {
        let none = ChatApprovalServices()
        let slack = action(tool: SlackSendProposal.tool, args: Self.slackArgs)
        XCTAssertFalse(AgentActionCard.editsSlack(slack, services: none))
        let failed = action(status: "failed")
        XCTAssertEqual(AgentActionCard.settledOffer(for: failed), .retry)
        XCTAssertEqual(AgentActionCard.shownSettledOffer(for: failed, services: none, offersRetry: true), .none)
        let unknown = action(tool: ConnectorCallProposal.tool, args: Self.connectorArgs, status: "failed",
                             error: ConnectorCallProposal.sessionEndedWhileRunning)
        XCTAssertEqual(AgentActionCard.settledOffer(for: unknown), .dismiss)
        XCTAssertEqual(AgentActionCard.shownSettledOffer(for: unknown, services: none, offersRetry: true), .none)
        let scope = action(tool: SlackSendProposal.tool, args: Self.slackArgs, status: "failed",
                           error: "not granted — " + SlackSendProposal.scopeHint)
        XCTAssertEqual(SlackSendProposal.reconnectAccountID(scope), 3)
        XCTAssertNil(AgentActionCard.reconnectAccount(scope, services: none))
        let connector = action(tool: ConnectorCallProposal.tool, args: Self.connectorArgs)
        XCTAssertFalse(AgentActionCard.connectorEditable(connector, services: none, sessionHolds: true))

        let all = ChatApprovalServices(approveEdited: true, retry: { _ in }, dismiss: { _ in },
                                       reconnectSlack: { _ in nil })
        XCTAssertTrue(AgentActionCard.editsSlack(slack, services: all))
        XCTAssertEqual(AgentActionCard.shownSettledOffer(for: failed, services: all, offersRetry: true), .retry)
        XCTAssertEqual(AgentActionCard.shownSettledOffer(for: failed, services: all, offersRetry: false), .none)
        XCTAssertEqual(AgentActionCard.shownSettledOffer(for: unknown, services: all, offersRetry: true), .dismiss)
        XCTAssertEqual(AgentActionCard.reconnectAccount(scope, services: all), 3)
        XCTAssertTrue(AgentActionCard.connectorEditable(connector, services: all, sessionHolds: true))
    }

    /// The card a running turn waits on is outlined; a settled one, another turn's, or no running turn is not.
    func testAwaitedOutlineFollowsRunningTurn() {
        let pending = action()
        XCTAssertTrue(AgentActionCard.isAwaited(pending, runningTurnID: "t1"))
        XCTAssertFalse(AgentActionCard.isAwaited(pending, runningTurnID: "t2"))
        XCTAssertFalse(AgentActionCard.isAwaited(pending, runningTurnID: nil))
        XCTAssertFalse(AgentActionCard.isAwaited(action(status: "applied"), runningTurnID: "t1"))
    }

    /// **Approve all** covers two or more pending cards of one turn, never a session call's.
    func testApproveAllNeedsTwoBulkApprovableCards() {
        XCTAssertNil(ApproveAllRow.turn(of: [action()]))
        XCTAssertEqual(ApproveAllRow.turn(of: [action(), action(tool: "create_jira_issue")]), "t1")
        XCTAssertNil(ApproveAllRow.turn(of: [action(), action(tool: ConnectorCallProposal.tool, args: Self.connectorArgs)]))
        XCTAssertNil(ApproveAllRow.turn(of: [action(), action(status: "applied")]))
    }

    // MARK: - Moved from the part's own parsers (ChatPartRegistryTests)

    func testSlackApprovalReadsRecipientAndText() throws {
        let card = ChatAgentAction(payload: payload(
            tool: "send_slack_message", args: ##"{"target": {"label": "#general", "workspace": "acme"}, "text": "hi"}"##
        ))
        let slack = try XCTUnwrap(SlackSendProposal(action: card))
        XCTAssertEqual(slack.target?.label, "#general")
        XCTAssertEqual(slack.target?.workspace, "acme")
        XCTAssertEqual(slack.text, "hi")
        XCTAssertNil(ConnectorCallProposal(action: card))
    }

    /// No recipient: the card falls back to the arguments; the app's own words name its host, never "the Mac" itself.
    func testSlackApprovalWithoutRecipientLeavesTheLineToTheApp() {
        let card = ChatAgentAction(payload: payload(tool: "send_slack_message", args: ##"{"text": "hi"}"##))
        XCTAssertNil(SlackSendProposal(action: card))
        XCTAssertEqual(AgentActionCard.summaryLines(for: card), [##"{"text": "hi"}"##])
        XCTAssertEqual(ChatHostText.plain.chooseSlackWorkspace, "Choose a workspace on your tower before approving")
        XCTAssertEqual(ChatHostText.plain.artifactCut, "This artifact is cut here; the whole text is on your tower.")
    }

    /// The header's tone: orange (waiting) only while the action waits for the owner (P5).
    func testHeaderWaitsOnlyWhilePending() {
        XCTAssertEqual(AgentActionCard.headerKind("pending"), .waiting)
        XCTAssertEqual(AgentActionCard.headerKind("applied"), .done)
        XCTAssertEqual(AgentActionCard.headerKind("failed"), .failed)
        XCTAssertEqual(AgentActionCard.headerKind("rejected"), .neutral)
        XCTAssertEqual(AgentActionCard.statusLabel(for: action(), sessionHolds: false), "Awaiting your approval")
    }

    /// The gesture error hides once the row settles or says the same; a `tracks start` failure outlives the row.
    func testGestureErrorRule() {
        let busy = ChatApprovalState(showsButtons: true, canAnswer: true, line: nil, gestureError: "SQLITE_BUSY",
                                     approveFailed: true)
        XCTAssertEqual(AgentActionCard.shownGestureError(busy, action: action()), "SQLITE_BUSY")
        XCTAssertNil(AgentActionCard.shownGestureError(busy, action: action(status: "applied")))
        XCTAssertNil(AgentActionCard.shownGestureError(busy, action: action(status: "failed", error: "SQLITE_BUSY")))
        let start = ChatApprovalState(showsButtons: true, canAnswer: true, line: nil, gestureError: "start failed",
                                      gestureErrorOutlivesRow: true)
        XCTAssertEqual(AgentActionCard.shownGestureError(start, action: action(status: "applied")), "start failed")
    }

    /// A daemon one version behind sends no `args_display` and no `args_complete`: the card draws no empty line.
    func testOldDaemonPayloadWithoutArgsShowsNoEmptyLine() {
        let card = ChatAgentAction(payload: payload(tool: "create_target", args: "", complete: false))
        XCTAssertTrue(card.argsClipped)
        XCTAssertEqual(AgentActionCard.bodyLines(for: card), [])
        let row = ChatAgentAction(id: 1, tool: "create_target", argsJSON: "{}")
        XCTAssertEqual(AgentActionCard.bodyLines(for: row), [""], "a row's lines are drawn as they are")
    }
}
