import XCTest
@testable import WatchtowerDesktop
@testable import WatchtowerCore
import WatchtowerTestSupport

/// An Inbox target button's state from its newest proposal (spec "The
/// Desktop button", every row of its table) and what a click then does.
final class TargetButtonStateResolverTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func stamp(_ secondsAgo: TimeInterval) -> String {
        ISO8601DateFormatter().string(from: now.addingTimeInterval(-secondsAgo))
    }

    private func proposal(
        _ status: String,
        decidedAgo: TimeInterval = 600,
        dismissed: Bool = false,
        error: String = "",
        result: String = ""
    ) throws -> InboxTargetButtonFacts.Proposal {
        let pool = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: pool.1) }
        let row = try pool.0.write { db -> AgentAction in
            let id = try TestDatabase.insertAgentAction(
                db, surface: "inbox", contextType: "automation_output", contextID: "5:0:abc",
                status: status, resultJSON: result, error: error, decidedAt: stamp(decidedAgo))
            if dismissed {
                try db.execute(sql: "UPDATE agent_actions SET dismissed_at = ? WHERE id = ?",
                               arguments: [stamp(10), id])
            }
            return try XCTUnwrap(AgentActionQueries.fetch(db, id: id))
        }
        return InboxTargetButtonFacts.Proposal(row)
    }

    private func state(_ facts: InboxTargetButtonFacts) -> ArtifactTargetButtonState {
        TargetButtonStateResolver.state(facts, now: now)
    }

    func testEveryRowOfTheTable() throws {
        XCTAssertEqual(state(InboxTargetButtonFacts()), .idle)
        XCTAssertEqual(state(InboxTargetButtonFacts(proposal: try proposal("pending"))), .waiting)
        XCTAssertEqual(state(InboxTargetButtonFacts(proposal: try proposal("approved", decidedAgo: 30))), .creating)
        XCTAssertEqual(state(InboxTargetButtonFacts(proposal: try proposal("executing", decidedAgo: 30))), .creating)
        let applied = try proposal("applied", result: #"{"target_id":42}"#)
        XCTAssertEqual(state(InboxTargetButtonFacts(proposal: applied, taskExists: true)), .created)
        // The task deleted since: pressable again.
        XCTAssertEqual(state(InboxTargetButtonFacts(proposal: applied, taskExists: false)), .idle)
        XCTAssertEqual(state(InboxTargetButtonFacts(proposal: try proposal("rejected"))), .idle)
        XCTAssertEqual(state(InboxTargetButtonFacts(proposal: try proposal("failed", error: "parent_id: task #3 is closed"))),
                       .failed(message: "parent_id: task #3 is closed"))
        XCTAssertEqual(state(InboxTargetButtonFacts(proposal: try proposal("failed", dismissed: true))), .idle)
        XCTAssertEqual(state(InboxTargetButtonFacts(pressError: "no such tool")), .proposeError(message: "no such tool"))
    }

    func testTargetButton_StuckOffersTryAgain() throws {
        for status in ["approved", "executing"] {
            // Two minutes after the approval with nothing of ours on it: stuck.
            let old = try proposal(status, decidedAgo: TargetButtonStateResolver.targetButtonStuckAfter)
            XCTAssertEqual(state(InboxTargetButtonFacts(proposal: old)), .stuck, status)
            // Our own apply still running: creating, however old.
            XCTAssertEqual(state(InboxTargetButtonFacts(proposal: old, inFlight: true)), .creating, status)
            // Under two minutes: creating.
            let fresh = try proposal(status, decidedAgo: TargetButtonStateResolver.targetButtonStuckAfter - 1)
            XCTAssertEqual(state(InboxTargetButtonFacts(proposal: fresh)), .creating, status)
            // A Try again whose CLI failed without moving the row: failed, still Try again.
            XCTAssertEqual(state(InboxTargetButtonFacts(proposal: old, applyError: "database is locked")),
                           .failed(message: "database is locked"), status)
        }
    }

    func testFailedTryAgainErrorWinsOverTheRowError() throws {
        let failed = try proposal("failed", error: "old reason")
        XCTAssertEqual(state(InboxTargetButtonFacts(proposal: failed, applyError: "new reason")),
                       .failed(message: "new reason"))
        XCTAssertEqual(state(InboxTargetButtonFacts(proposal: try proposal("failed"))),
                       .failed(message: "The task was not created."))
    }

    /// A propose that failed after a rejected or deleted-task row: the
    /// button is idle with the reason.
    func testProposeErrorOverAnIdleRow() throws {
        XCTAssertEqual(state(InboxTargetButtonFacts(proposal: try proposal("rejected"), pressError: "x")),
                       .proposeError(message: "x"))
    }

    // MARK: - What a click does

    private let card = AutomationOutputCard(
        id: 5, automationID: 2, automationName: "Acme digest", runID: 9, title: "Weekly",
        body: "", priority: "medium", createdAt: Date(timeIntervalSince1970: 0))
    private let target = InboxCardAction.Target(title: "Sign off", intent: nil, parent: nil, hash: "abc")

    private func click(_ facts: InboxTargetButtonFacts) -> InboxCardCommand? {
        InboxCardPress.target(target, index: 0, card: card, facts: facts, state: state(facts))
    }

    func testClickByState() throws {
        XCTAssertEqual(click(InboxTargetButtonFacts()),
                       .proposeTarget(InboxTargetPress(card: card, index: 0, target: target)))
        XCTAssertEqual(click(InboxTargetButtonFacts(pressError: "x")),
                       .proposeTarget(InboxTargetPress(card: card, index: 0, target: target)))
        let pending = try proposal("pending")
        XCTAssertEqual(click(InboxTargetButtonFacts(proposal: pending)), .openProposal(pending.id))
        let stuck = try proposal("executing")
        XCTAssertEqual(click(InboxTargetButtonFacts(proposal: stuck)), .tryAgainTarget(stuck.id))
        let failed = try proposal("failed")
        XCTAssertEqual(click(InboxTargetButtonFacts(proposal: failed)), .tryAgainTarget(failed.id))
        XCTAssertNil(click(InboxTargetButtonFacts(proposal: try proposal("approved", decidedAgo: 5))))
        let applied = try proposal("applied", result: #"{"target_id":42}"#)
        XCTAssertEqual(click(InboxTargetButtonFacts(proposal: applied, taskExists: true)), .openTarget(42))
    }

    func testProposingHoldsTheClick() {
        let source = InboxTargetButtonSource(isProposing: { _ in true }, now: now)
        XCTAssertNil(source.command(target, index: 0, card: card))
    }

    /// The button reads its facts under exactly the drawn action's context.
    func testTargetButton_RewriteNeverInheritsState() throws {
        let pending = try proposal("pending")
        let source = InboxTargetButtonSource(
            facts: { $0 == "5:0:abc" ? InboxTargetButtonFacts(proposal: pending) : InboxTargetButtonFacts() },
            now: now)
        XCTAssertEqual(source.button(target, index: 0, card: card).state, .waiting)
        let rewritten = InboxCardAction.Target(title: "Sign off v2", intent: nil, parent: nil, hash: "def")
        XCTAssertEqual(source.button(rewritten, index: 0, card: card).state, .idle)
        XCTAssertEqual(source.button(target, index: 1, card: card).state, .idle)
    }
}

/// The Kit's decoding gives a target press the action's hash (Go
/// `blocks.ActionHash`), on block cards and markdown cards alike.
final class InboxTargetActionDecodeTests: XCTestCase {
    func testKitActionCarriesItsHash() throws {
        let action = ArtifactAction(label: "Make a task",
                                    payload: .target(ArtifactTargetAction(title: "Sign off", intent: "Friday", parent: 3)))
        let decoded = try XCTUnwrap(InboxCardAction(action, index: 4))
        let expected = InboxCardAction.Target(title: "Sign off", intent: "Friday", parent: 3, hash: action.hash)
        XCTAssertEqual(decoded.kind, .target(expected))
        XCTAssertEqual(decoded.index, 4)
    }

    func testMarkdownCardDecodesItsTargetAction() {
        let card = AutomationOutputCard(
            id: 5, automationID: 2, automationName: "Acme digest", runID: 9, title: "Weekly", body: "b",
            priority: "medium", createdAt: Date(timeIntervalSince1970: 0),
            actionsJSON: #"[{"label":"Ask","kind":"chat","chat":"Hi"},{"label":"Task","kind":"target","target":{"title":"Do it"}}]"#)
        let actions = InboxCardAction.ownActions(card)
        XCTAssertEqual(actions.map(\.index), [0, 1])
        guard case .target(let target) = actions[1].kind else { return XCTFail("a target action") }
        XCTAssertEqual(target.title, "Do it")
        XCTAssertEqual(target.hash.count, 16)
    }
}
