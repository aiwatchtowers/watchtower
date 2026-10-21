import XCTest
@testable import WatchtowerCore

/// An Inbox card's own buttons, decoded from `automation_outputs.actions_json`
/// (Go `db.InboxAction`): tolerant, never throws, `data` stays in Go.
final class InboxCardActionTests: XCTestCase {
    /// The stored form of Task 2's `TestOutput_InboxCardRoundTrip` card.
    private let fourKinds = """
        [{"label":"Open","kind":"link","open":"watchtower-nav://automations","primary":true},\
        {"label":"Ask","kind":"chat","chat":"Draft replies"},\
        {"label":"Fix","kind":"agent","agent":{"task":"Fix it","workbench":3}},\
        {"label":"Backlog","kind":"reply","reply":"backlog","data":{"id":"A-1"}}]
        """

    func testDecodesFourKinds() throws {
        let actions = InboxCardAction.decode(fourKinds)
        let nav = try XCTUnwrap(URL(string: "watchtower-nav://automations"))
        XCTAssertEqual(actions, [
            InboxCardAction(index: 0, label: "Open", kind: .link(nav), primary: true),
            InboxCardAction(index: 1, label: "Ask", kind: .chat("Draft replies"), primary: false),
            InboxCardAction(index: 2, label: "Fix", kind: .agent(task: "Fix it", workbench: .id(3)), primary: false),
            InboxCardAction(index: 3, label: "Backlog", kind: .reply(value: "backlog"), primary: false)
        ])
    }

    func testUnknownKindIsDropped() {
        let actions = InboxCardAction.decode("""
            [{"label":"X","kind":"teleport"},{"label":"Open","kind":"link","open":"https://example.com/a"},\
            {"label":"Bad","kind":"link","open":""},{"label":"Later","kind":"reply","reply":"later"}]
            """)
        XCTAssertEqual(actions.map(\.label), ["Open", "Later"])
        // A Reply press names the stored position, not the decoded one.
        XCTAssertEqual(actions.map(\.index), [1, 3])
    }

    func testGarbledJSONIsEmpty() {
        XCTAssertEqual(InboxCardAction.decode("not json"), [])
        XCTAssertEqual(InboxCardAction.decode("{}"), [])
        XCTAssertEqual(InboxCardAction.decode(""), [])
    }

    func testWorkbenchRef() {
        func ref(_ workbench: String?) -> InboxCardAction.WorkbenchRef?? {
            let agent = workbench.map { #"{"task":"T","workbench":\#($0)}"# } ?? #"{"task":"T"}"#
            let actions = InboxCardAction.decode(#"[{"label":"Fix","kind":"agent","agent":\#(agent)}]"#)
            guard case let .agent(_, workbench)? = actions.first?.kind else { return .none }
            return .some(workbench)
        }
        XCTAssertEqual(ref("3"), .some(.id(3)))
        XCTAssertEqual(ref(#""acme""#), .some(.name("acme")))
        XCTAssertEqual(ref(nil), .some(nil))
    }

    func testReplyState() {
        func card(_ state: AutomationHeaderButton.State, pressed: Int? = nil, run: Int64? = nil) -> AutomationOutputCard {
            AutomationOutputCard(id: 1, automationID: 2, automationName: "Triage", runID: 3, title: "T", body: "B",
                                 priority: "medium", createdAt: Date(), pressedAction: pressed, pressedRunID: run,
                                 recipeState: state)
        }
        XCTAssertEqual(InboxCardAction.replyState(card(.runnable, pressed: 0, run: 9)), .sent(runID: 9))
        // A press wins over the recipe's state; its run may since be deleted.
        XCTAssertEqual(InboxCardAction.replyState(card(.disabled, pressed: 1)), .sent(runID: nil))
        XCTAssertEqual(InboxCardAction.replyState(card(.runnable)), .ready)
        XCTAssertEqual(InboxCardAction.replyState(card(.needsConfirmation)), .needsConfirmation)
        XCTAssertEqual(InboxCardAction.replyState(card(.disabled)), .off)
        XCTAssertEqual(InboxCardAction.replyState(card(.parseError)), .unreadable)
    }
}
