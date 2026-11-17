import XCTest
@testable import WatchtowerCore
import WatchtowerTestSupport

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

    /// A Reply's state is Go's (`inboxfeed.replyState`, its cases in
    /// `internal/inboxfeed`): the Mac draws the feed's label, closed state
    /// and caption, and sends only a Reply Go says is ready.
    func testReplyStateIsTheFeeds() {
        let sent = InboxFeedButtons(TestInboxFeeds.artifact(1, actions: [
            TestInboxFeeds.reply(0, label: "Sent — run #9", detail: "sent", state: .pressed),
            TestInboxFeeds.reply(1, label: "Later", detail: "sent", state: .pressed)
        ]))
        XCTAssertEqual(sent.label(at: 0, recipe: "Backlog"), "Sent — run #9")
        XCTAssertEqual(sent.label(at: 1, recipe: "Later"), "Later")
        XCTAssertTrue(sent.replyClosed(at: 0))
        XCTAssertFalse(sent.replySends(at: 0))
        XCTAssertNil(sent.replyCaption)
        XCTAssertEqual(sent.replyLine(pressed: 0), "Sent — run #9")
        XCTAssertEqual(sent.replyLine(pressed: nil), InboxFeedButtons.sentLabel)
        XCTAssertEqual(InboxFeedButtons.sentLabel, "Sent")

        let ready = InboxFeedButtons(TestInboxFeeds.artifact(1, actions: [TestInboxFeeds.reply(0, label: "Go", detail: "ready")]))
        XCTAssertTrue(ready.replySends(at: 0))
        XCTAssertFalse(ready.replyClosed(at: 0))
        XCTAssertNil(ready.replyLine(pressed: nil))

        let off = InboxFeedButtons(TestInboxFeeds.artifact(1, actions: [
            TestInboxFeeds.reply(0, label: "Go", detail: "needs_confirmation", note: "Needs confirmation")
        ]))
        XCTAssertFalse(off.replySends(at: 0), "opens its automation")
        XCTAssertFalse(off.replyClosed(at: 0))
        XCTAssertEqual(off.replyCaption, "Needs confirmation")
        XCTAssertEqual(off.replyLine(pressed: nil), "Needs confirmation")

        let removed = InboxFeedButtons(TestInboxFeeds.artifact(1, actions: [
            TestInboxFeeds.reply(0, label: "Go", detail: "removed", note: "Recipe removed", state: .disabled)
        ]))
        XCTAssertTrue(removed.replyClosed(at: 0))
        XCTAssertEqual(removed.replyCaption, "Recipe removed")

        // No feed: a Reply draws closed under its recipe label.
        let none = InboxFeedButtons(nil)
        XCTAssertTrue(none.replyClosed(at: 0))
        XCTAssertEqual(none.label(at: 0, recipe: "Go"), "Go")
        XCTAssertNil(none.replyCaption)
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
