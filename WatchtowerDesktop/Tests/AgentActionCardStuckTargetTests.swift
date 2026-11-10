import XCTest
import GRDB
import SwiftUI
import ViewInspector
@testable import WatchtowerDesktop
@testable import WatchtowerCore
import WatchtowerTestSupport

/// The approval card of an Inbox target button's proposal (Inbox builder A,
/// spec "A proposal stuck in approved or executing"): the stuck rule and
/// Try again apply there as on the button, on the same row.
@MainActor
final class AgentActionCardStuckTargetTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func row(_ status: String, decidedAgo: TimeInterval) throws -> AgentAction {
        let queue = try TestDatabase.create()
        let decided = ISO8601DateFormatter().string(from: now.addingTimeInterval(-decidedAgo))
        return try queue.write { db in
            let id = try TestDatabase.insertAgentAction(
                db, surface: "inbox", contextType: "automation_output", contextID: "5:0:abc",
                status: status, decidedAt: decided)
            return try XCTUnwrap(AgentActionQueries.fetch(db, id: id))
        }
    }

    private func card(_ action: AgentAction, inFlight: Bool = false, onRetry: @escaping () -> Void = {})
        -> AgentActionCardView {
        let facts = InboxTargetButtonFacts(proposal: .init(action), inFlight: inFlight)
        return AgentActionCardView(
            action: action, inFlight: inFlight, onApprove: {}, onReject: {}, onRetry: onRetry,
            targetButtonState: TargetButtonStateResolver.state(facts, now: now))
    }

    func testApprovalCard_StuckTargetProposalTryAgain() throws {
        for status in ["approved", "executing"] {
            let action = try row(status, decidedAgo: 120)
            var retried = 0
            let sut = card(action) { retried += 1 }
            XCTAssertNoThrow(try sut.inspect().find(text: "Didn't finish"), status)
            try sut.inspect().find(ArtifactTargetStuckLine.self).find(button: "Try again").tap()
            XCTAssertEqual(retried, 1, status)
        }
    }

    func testUnderTwoMinutesShowsInFlight() throws {
        for status in ["approved", "executing"] {
            for sut in [card(try row(status, decidedAgo: 30)),
                        card(try row(status, decidedAgo: 600), inFlight: true)] {
                XCTAssertThrowsError(try sut.inspect().find(ArtifactTargetStuckLine.self), status)
                XCTAssertNoThrow(try sut.inspect().find(viewWithAccessibilityIdentifier: "agentAction.targetCreating"),
                                 status)
                XCTAssertThrowsError(try sut.inspect().find(button: "Retry"), status)
                XCTAssertThrowsError(try sut.inspect().find(button: "Try again"), status)
            }
        }
    }

    /// A stuck row whose Try again failed without moving it (the button
    /// shows `.failed`) keeps Try again on the card; a `failed` row keeps
    /// the card's own Retry.
    func testFailedTryAgainOnAStuckRowKeepsTryAgain() throws {
        for status in ["approved", "executing"] {
            let action = try row(status, decidedAgo: 600)
            var retried = 0
            let sut = AgentActionCardView(
                action: action, inFlight: false, onApprove: {}, onReject: {}, onRetry: { retried += 1 },
                targetButtonState: .failed(message: "database is locked"))
            try sut.inspect().find(ArtifactTargetStuckLine.self).find(button: "Try again").tap()
            XCTAssertEqual(retried, 1, status)
        }
        let failed = try row("failed", decidedAgo: 600)
        let sut = AgentActionCardView(action: failed, inFlight: false, onApprove: {}, onReject: {}, onRetry: {},
                                      targetButtonState: .failed(message: "closed"))
        XCTAssertThrowsError(try sut.inspect().find(ArtifactTargetStuckLine.self))
        XCTAssertNoThrow(try sut.inspect().find(button: "Retry"))
    }

    /// An older row of a button whose newest row is another one offers no Retry.
    func testSupersededRowOffersNoRetry() throws {
        let action = try row("failed", decidedAgo: 600)
        let offered = AgentActionCardView(action: action, inFlight: false, onApprove: {}, onReject: {}, onRetry: {})
        XCTAssertNoThrow(try offered.inspect().find(button: "Retry"))
        var hidden = offered
        hidden.offersRetry = false
        XCTAssertThrowsError(try hidden.inspect().find(button: "Retry"))
    }
}
