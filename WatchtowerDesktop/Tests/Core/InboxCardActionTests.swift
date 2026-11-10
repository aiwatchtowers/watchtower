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
        XCTAssertEqual(ref("3.5"), .some(nil))
        XCTAssertEqual(ref("true"), .some(nil))
        XCTAssertEqual(ref("9007199254740993"), .some(.id(9_007_199_254_740_993)))
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

/// A target button's press (Inbox builder A, spec "The press"): the args are
/// the drawn action's, the reason names the card, the context names the
/// output, the index and the action's hash, and nothing approves it.
final class InboxTargetPressTests: XCTestCase {
    private func card(title: String = "Weekly review") -> AutomationOutputCard {
        AutomationOutputCard(id: 7, automationID: 2, automationName: "Acme digest", runID: 9, title: title,
                             body: "", priority: "medium", createdAt: Date(timeIntervalSince1970: 0))
    }

    private func args(_ press: InboxTargetPress) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(press.argsJSON.utf8)) as? [String: Any])
    }

    func testArgsEqualTheDrawnAction() throws {
        let target = InboxCardAction.Target(title: "Sign off the checklist", intent: "Release is Friday",
                                            parent: 12, hash: "0123456789abcdef")
        let press = InboxTargetPress(card: card(), index: 2, target: target)
        XCTAssertEqual(press.contextID, "7:2:0123456789abcdef")
        let object = try args(press)
        XCTAssertEqual(object["text"] as? String, "Sign off the checklist")
        XCTAssertEqual(object["intent"] as? String, "Release is Friday")
        XCTAssertEqual((object["parent_id"] as? NSNumber)?.int64Value, 12)
        XCTAssertEqual(object["reason"] as? String, "From the Inbox card \u{201C}Weekly review\u{201D} of Acme digest")
        XCTAssertEqual(press.arguments, [
            "actions", "propose", "--tool", "create_target", "--surface", "inbox",
            "--context-type", "automation_output", "--context-id", "7:2:0123456789abcdef",
            "--args", press.argsJSON, "--json"
        ])
        XCTAssertFalse(press.arguments.contains("--approve"))
    }

    func testOptionalFieldsAreLeftOut() throws {
        let press = InboxTargetPress(card: card(title: ""), index: 0,
                                     target: InboxCardAction.Target(title: "Do it", intent: nil, parent: nil, hash: "h"))
        let object = try args(press)
        XCTAssertEqual(Set(object.keys), ["text", "reason"])
        XCTAssertEqual(object["reason"] as? String, "From the Inbox card \u{201C}Automation output\u{201D} of Acme digest")
    }

    /// Core's tolerant decoder cannot hash, so it drops a target action
    /// without moving the next one's index.
    func testCoreDecodeDropsTargetKeepingIndexes() {
        let actions = InboxCardAction.decode(#"""
            [{"label":"Task","kind":"target","target":{"title":"Do it"}},{"label":"Ask","kind":"chat","chat":"Hi"}]
            """#)
        XCTAssertEqual(actions.map(\.index), [1])
    }
}
