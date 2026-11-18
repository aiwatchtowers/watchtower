import ChatWire
import SwiftUI
import XCTest
@testable import ChatUI

/// Retry and Dismiss in the shared approval card (mobile Inbox spec §12.2–§12.4, board #2018): the card's own rule
/// decides where each shows, and a device that may not act gets the note in its place.
final class AgentActionCardDecisionTests: XCTestCase {
    private func action(
        tool: String = "create_jira_issue", status: String = "failed", error: String = "jira: 503", dismissedAt: String = ""
    ) -> ChatAgentAction {
        ChatAgentAction(id: 9, tool: tool, external: true, argsJSON: #"{"summary":"x"}"#, argsStored: false,
                        argsSHA256: "b2", status: status, error: error, dismissedAt: dismissedAt)
    }

    private var unknownOutcome: ChatAgentAction {
        action(tool: ConnectorCallProposal.tool, error: ConnectorCallProposal.sessionEndedWhileRunning)
    }

    private let wired = ChatApprovalServices(retry: { _ in }, dismiss: { _ in })

    /// Retry on a failed row (and a stuck approved one), never on a superseded Inbox-button row or a session call.
    func testSettledOfferRetry() {
        XCTAssertEqual(AgentActionCard.settledOffer(for: action()), .retry)
        XCTAssertEqual(AgentActionCard.settledOffer(for: action(status: "approved", error: "")), .retry)
        XCTAssertEqual(AgentActionCard.settledOffer(for: action(status: "applied", error: "")), .none)
        XCTAssertEqual(AgentActionCard.settledRow(for: action(), services: wired, offersRetry: true, state: nil), .offer(.retry))
        XCTAssertEqual(AgentActionCard.settledRow(for: action(), services: wired, offersRetry: false, state: nil), .none,
                       "a superseded button row offers no Retry")
    }

    /// Dismiss only on a session call whose outcome is unknown, the one row Go dismisses (ask #1549 Q1 = A); an ordinary
    /// failed row never offers it, and a dismissed call stops offering it.
    func testDismissOnlyOnUnknownOutcome() {
        XCTAssertEqual(AgentActionCard.settledRow(for: unknownOutcome, services: wired, offersRetry: true, state: nil),
                       .offer(.dismiss))
        XCTAssertNotEqual(AgentActionCard.settledRow(for: action(), services: wired, offersRetry: true, state: nil),
                          .offer(.dismiss))
        let otherSessionFailure = action(tool: ConnectorCallProposal.tool, error: ConnectorCallProposal.stopped)
        XCTAssertEqual(AgentActionCard.settledRow(for: otherSessionFailure, services: wired, offersRetry: true, state: nil), .none)
        let dismissed = action(tool: ConnectorCallProposal.tool, error: ConnectorCallProposal.sessionEndedWhileRunning,
                               dismissedAt: "2026-11-18T09:00:00Z")
        XCTAssertEqual(AgentActionCard.settledRow(for: dismissed, services: wired, offersRetry: true, state: nil), .none)
    }

    /// Without the grant (or on an older hub) the offer becomes its note; a row with nothing to offer gets no note.
    func testSettledNoteReplacesTheOffer() {
        let noGrant = ChatApprovalState(showsButtons: true, canAnswer: true, line: nil, settledNote: "Retry on the Mac")
        XCTAssertEqual(AgentActionCard.settledRow(for: action(), services: wired, offersRetry: true, state: noGrant),
                       .note("Retry on the Mac"))
        XCTAssertEqual(AgentActionCard.settledRow(for: action(), services: ChatApprovalServices(), offersRetry: true, state: noGrant),
                       .note("Retry on the Mac"), "the note shows whether or not the screen wired Retry")
        XCTAssertEqual(AgentActionCard.settledRow(for: action(status: "applied", error: ""), services: wired, offersRetry: true,
                                                  state: noGrant), .none)
        XCTAssertEqual(AgentActionCard.settledRow(for: action(), services: wired, offersRetry: false, state: noGrant), .none)
    }

    /// The line shows on a pending row, and on a settled one only while it offers (or notes) Retry or Dismiss.
    func testLineShowsOnSettledRowsWithAnOffer() {
        let busy = ChatApprovalState(showsButtons: true, canAnswer: false, line: "Retrying…", inFlight: true)
        XCTAssertEqual(AgentActionCard.shownLine(for: action(), services: wired, offersRetry: true, state: busy), "Retrying…")
        XCTAssertNil(AgentActionCard.shownLine(for: action(status: "applied", error: ""), services: wired, offersRetry: true,
                                               state: busy))
        XCTAssertEqual(AgentActionCard.shownLine(for: action(status: "pending", error: ""), services: wired, offersRetry: true,
                                                 state: busy), "Retrying…")
        XCTAssertNil(AgentActionCard.shownLine(for: action(), services: wired, offersRetry: true, state: nil))
        XCTAssertEqual(AgentActionCard.availability(busy), .disabled, "a press on its way turns the settled row off too")
    }
}

/// The state the screens hand the card (mobile Inbox spec §12.4): every new field defaults off, so the Mac and the
/// phone chat draw what they drew before.
final class ChatApprovalStateTests: XCTestCase {
    func testNewFieldsDefaultOff() {
        let state = ChatApprovalState(showsButtons: true, canAnswer: true, line: nil)
        XCTAssertNil(state.approveNote)
        XCTAssertNil(state.settledNote)
        XCTAssertNil(state.undelivered)
        XCTAssertNil(ChatApprovalServices().resend)
        let failed = ChatAgentAction(id: 1, tool: "create_jira_issue", status: "failed", error: "x")
        let mac = ChatApprovalServices(retry: { _ in }, dismiss: { _ in })
        XCTAssertEqual(AgentActionCard.settledRow(for: failed, services: mac, offersRetry: true, state: state), .offer(.retry))
        XCTAssertNil(AgentActionCard.shownLine(for: failed, services: mac, offersRetry: true, state: state))
    }

    func testUndeliveredCarriesItsLineAndNamedRetry() {
        let undelivered = ChatApprovalState.Undelivered(line: "Not delivered — Acme Mac didn't get it.", retryTitle: "Retry Approve")
        let state = ChatApprovalState(showsButtons: true, canAnswer: true, line: nil, undelivered: undelivered)
        XCTAssertEqual(state.undelivered?.retryTitle, "Retry Approve")
        XCTAssertEqual(state.undelivered?.line, "Not delivered — Acme Mac didn't get it.")
    }
}
