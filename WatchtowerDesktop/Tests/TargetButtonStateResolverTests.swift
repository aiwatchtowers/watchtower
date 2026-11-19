import XCTest
@testable import WatchtowerDesktop
@testable import WatchtowerCore
import WatchtowerInterface
import WatchtowerTestSupport

/// An Inbox target button's state (spec "The Desktop button", every row of
/// its table): Go's state from the feed (`InboxTargetButton.detail`,
/// decided in `internal/inboxfeed` `targetState`) with this Desktop's own
/// processes laid over it, and what a click then does.
final class TargetButtonStateResolverTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func state(_ button: InboxTargetButton) -> ArtifactTargetButtonState {
        TargetButtonStateResolver.state(button, now: now)
    }

    private func button(
        _ detail: String,
        note: String = "",
        untilIn seconds: TimeInterval? = nil,
        proposal: Int64? = 7,
        task: Int64? = nil,
        inFlight: Bool = false,
        pressError: String? = nil,
        applyError: String? = nil
    ) -> InboxTargetButton {
        InboxTargetButton(detail: detail, note: note, until: seconds.map { now.addingTimeInterval($0) },
                          proposalID: proposal, taskID: task, inFlight: inFlight,
                          pressError: pressError, applyError: applyError)
    }

    func testEveryRowOfTheTable() {
        XCTAssertEqual(state(InboxTargetButton()), .idle)
        XCTAssertEqual(state(button("idle")), .idle)
        XCTAssertEqual(state(button("waiting")), .waiting)
        XCTAssertEqual(state(button("creating", untilIn: 90)), .creating)
        XCTAssertEqual(state(button("stuck")), .stuck)
        XCTAssertEqual(state(button("created", task: 42)), .created)
        XCTAssertEqual(state(button("failed", note: "parent_id: task #3 is closed")),
                       .failed(message: "parent_id: task #3 is closed"))
        XCTAssertEqual(state(InboxTargetButton(pressError: "no such tool")), .proposeError(message: "no such tool"))
        // A state this build does not know draws idle.
        XCTAssertEqual(state(button("archived")), .idle)
    }

    func testTargetButton_StuckOffersTryAgain() {
        // Go's `until` passed with nothing of ours on it: stuck, by the Mac's clock.
        XCTAssertEqual(state(button("creating", untilIn: 0)), .stuck)
        XCTAssertEqual(state(button("creating")), .stuck, "no readable until")
        for detail in ["creating", "stuck"] {
            // Our own apply still running: creating, however old.
            XCTAssertEqual(state(button(detail, untilIn: -600, inFlight: true)), .creating, detail)
            // A Try again whose apply failed without moving the row: failed, still Try again.
            XCTAssertEqual(state(button(detail, untilIn: -1, applyError: "database is locked")),
                           .failed(message: "database is locked"), detail)
        }
        // Before `until` the apply error waits: the row may still move.
        XCTAssertEqual(state(button("creating", untilIn: 30, applyError: "database is locked")), .creating)
    }

    func testFailedTryAgainErrorWinsOverTheRowError() {
        XCTAssertEqual(state(button("failed", note: "old reason", applyError: "new reason")),
                       .failed(message: "new reason"))
        XCTAssertEqual(state(button("failed")), .failed(message: TargetButtonStateResolver.notCreated))
        XCTAssertEqual(TargetButtonStateResolver.notCreated, "The task was not created.")
    }

    /// A propose that failed after a rejected or deleted-task row: the
    /// button is idle with the reason.
    func testProposeErrorOverAnIdleRow() {
        XCTAssertEqual(state(button("idle", pressError: "x")), .proposeError(message: "x"))
        XCTAssertEqual(state(button("waiting", pressError: "x")), .waiting, "a newer row wins")
    }

    /// Go's state comes off the feed's action and approval card as sent.
    func testStateFromTheFeed() throws {
        let action = CardAction(index: 0, kind: "target", label: "Make a task", state: .pressed, detail: "creating",
                                note: "", until: "2027-01-15T08:02:00Z")
        let fromAction = InboxTargetButton(action: action)
        XCTAssertEqual(fromAction.detail, "creating")
        XCTAssertEqual(fromAction.until, ISO8601DateFormatter().date(from: "2027-01-15T08:02:00Z"))
        XCTAssertEqual(InboxTargetButton(action: nil), InboxTargetButton())
        XCTAssertEqual(InboxTargetButton.date("2027-01-15T08:02:00.5Z")?.timeIntervalSince1970,
                       try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-15T08:02:00Z")).timeIntervalSince1970 + 0.5)
        XCTAssertNil(InboxTargetButton.date(""))

        var approval = TestInboxFeeds.approval(title: "Create task")
        XCTAssertNil(InboxTargetButton(approval: approval), "not a target button's row")
        XCTAssertNil(InboxTargetButton(approval: nil))
        approval.target = "failed"
        approval.targetNote = "closed"
        XCTAssertEqual(InboxTargetButton(approval: approval), InboxTargetButton(detail: "failed", note: "closed"))
    }

    // MARK: - What a click does

    private let card = AutomationOutputCard(
        id: 5, automationID: 2, automationName: "Acme digest", runID: 9, title: "Weekly",
        body: "", priority: "medium", createdAt: Date(timeIntervalSince1970: 0))
    private let target = InboxCardAction.Target(title: "Sign off", intent: nil, parent: nil, hash: "abc")

    private func click(_ button: InboxTargetButton) -> InboxCardCommand? {
        InboxCardPress.target(target, index: 0, card: card, button: button, state: state(button))
    }

    func testClickByState() {
        XCTAssertEqual(click(InboxTargetButton()),
                       .proposeTarget(InboxTargetPress(card: card, index: 0, target: target)))
        XCTAssertEqual(click(InboxTargetButton(pressError: "x")),
                       .proposeTarget(InboxTargetPress(card: card, index: 0, target: target)))
        XCTAssertEqual(click(button("waiting", proposal: 3)), .openProposal(3))
        XCTAssertEqual(click(button("stuck", proposal: 4)), .tryAgainTarget(4))
        XCTAssertEqual(click(button("failed", note: "closed", proposal: 5)), .tryAgainTarget(5))
        XCTAssertNil(click(button("creating", untilIn: 60)))
        // The task by its `source_id`, not the result's id.
        XCTAssertEqual(click(button("created", task: 42)), .openTarget(42))
    }

    func testProposingHoldsTheClick() {
        let source = InboxTargetButtonSource(isProposing: { _ in true }, now: now)
        XCTAssertNil(source.command(target, index: 0, card: card))
    }

    /// The button reads its state under exactly the drawn action's context
    /// and press index.
    func testTargetButton_RewriteNeverInheritsState() {
        let feedCard = TestInboxFeeds.artifact(5, actions: [
            CardAction(index: 0, kind: "target", label: "Sign off", state: .pressed, detail: "waiting",
                       note: "", until: "")
        ])
        let source = InboxTargetButtonSource(
            card: { $0 == 5 ? feedCard : nil },
            button: { context, action in
                var drawn = InboxTargetButton(action: action)
                drawn.proposalID = context == "5:0:abc" ? 3 : nil
                return drawn
            },
            now: now)
        XCTAssertEqual(source.button(target, index: 0, card: card).state, .waiting)
        XCTAssertEqual(source.button(target, index: 0, card: card).button.proposalID, 3)
        let rewritten = InboxCardAction.Target(title: "Sign off v2", intent: nil, parent: nil, hash: "def")
        XCTAssertNil(source.button(rewritten, index: 0, card: card).button.proposalID)
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
