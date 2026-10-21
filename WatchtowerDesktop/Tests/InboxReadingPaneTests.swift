import XCTest
import GRDB
import SwiftUI
import ViewInspector
@testable import WatchtowerDesktop
import WatchtowerCore

/// The Inbox reading pane (spec B1, B2): an automation card's own buttons
/// from its stored `actions`, then the common row; Reply's states; links
/// checked again by `InboxCardLinkPolicy`.
@MainActor
final class InboxReadingPaneTests: XCTestCase {
    private func card(
        actions: String = "[]",
        link: String = "",
        pressedAction: Int? = nil,
        pressedRunID: Int64? = nil,
        recipeState: AutomationHeaderButton.State = .runnable
    ) -> AutomationOutputCard {
        AutomationOutputCard(
            id: 5, automationID: 2, automationName: "Issue triage", runID: 212,
            title: "ACME-482: crash when importing CSV", body: "**Verdict:** bug, high priority.",
            priority: "high", createdAt: Date(timeIntervalSinceReferenceDate: 800_000_000),
            link: link, actionsJSON: actions, pressedAction: pressedAction, pressedRunID: pressedRunID,
            recipeState: recipeState
        )
    }

    private let twoActions = #"[{"label":"Move to Backlog","kind":"reply","reply":"backlog","primary":true},"#
        + #"{"label":"Draft a Reply","kind":"chat","chat":"Draft a reply"}]"#

    private func pane(
        _ card: AutomationOutputCard,
        navScreens: Set<String> = [],
        onCommand: @escaping (InboxCardCommand) -> Void = { _ in }
    ) -> InboxReadingPane {
        InboxReadingPane(item: .output(card), navScreens: navScreens, onCommand: onCommand)
    }

    private func buttonLabels(_ view: InboxReadingPane) throws -> [String] {
        try view.inspect().findAll(ViewType.Button.self).map { try $0.labelView().text().string() }
    }

    func testOutputPaneRendersMarkdownAndOwnButtons() throws {
        let sut = pane(card(actions: twoActions, link: "https://example.com/issue/482"))

        XCTAssertNoThrow(try sut.inspect().find(MarkdownView.self))
        XCTAssertNoThrow(try sut.inspect().find(text: "ACME-482: crash when importing CSV"))
        XCTAssertEqual(try buttonLabels(sut), [
            "Move to Backlog", "Draft a Reply", "Open source", "Discuss in Chat", "Hand to Agent…", "Done", "Dismiss"
        ])
    }

    func testOpenSourceHiddenWithoutLink() throws {
        let sut = pane(card(actions: twoActions))

        XCTAssertThrowsError(try sut.inspect().find(button: "Open source"))
        XCTAssertNoThrow(try sut.inspect().find(button: "Discuss in Chat"))
    }

    func testCommonRowEmitsItsCommands() throws {
        var commands: [InboxCardCommand] = []
        let shown = card(link: "https://example.com/issue/482")
        let sut = pane(shown) { commands.append($0) }

        try sut.inspect().find(button: "Open source").tap()
        try sut.inspect().find(button: "Discuss in Chat").tap()
        try sut.inspect().find(button: "Hand to Agent…").tap()

        XCTAssertEqual(commands, [
            .openLink(try XCTUnwrap(URL(string: "https://example.com/issue/482"))),
            .chat(card: shown, message: InboxCardTexts.discussMessage(shown)),
            .agent(card: shown, task: InboxCardTexts.handToAgentTask(shown), workbench: nil)
        ])
    }

    func testOwnButtonsEmitTheirKind() throws {
        var commands: [InboxCardCommand] = []
        // The bad first action is dropped; Reply keeps its stored index (2).
        let actions = #"[{"label":"Bad","kind":"teleport"},{"label":"Ask","kind":"agent","#
            + #""agent":{"task":"Fix it","workbench":3}},{"label":"Backlog","kind":"reply","reply":"backlog"}]"#
        let shown = card(actions: actions)
        let sut = pane(shown) { commands.append($0) }

        try sut.inspect().find(button: "Ask").tap()
        try sut.inspect().find(button: "Backlog").tap()

        XCTAssertEqual(commands, [.agent(card: shown, task: "Fix it", workbench: .id(3)),
                                  .reply(outputID: 5, action: 2)])
    }

    func testReplyButtonStates() throws {
        let reply = #"[{"label":"Move to Backlog","kind":"reply","reply":"backlog","primary":true}]"#

        let sent = pane(card(actions: reply, pressedAction: 0, pressedRunID: 7))
        XCTAssertTrue(try sent.inspect().find(button: "Sent — run #7").isDisabled())
        XCTAssertThrowsError(try sent.inspect().find(button: "Move to Backlog"))

        for (state, caption) in [(AutomationHeaderButton.State.needsConfirmation, "Needs confirmation"),
                                 (.disabled, "Off"), (.parseError, "Recipe can't be read")] {
            var commands: [InboxCardCommand] = []
            let shown = card(actions: reply, recipeState: state)
            let sut = pane(shown) { commands.append($0) }
            XCTAssertNoThrow(try sut.inspect().find(text: caption), caption)
            try sut.inspect().find(button: "Move to Backlog").tap()
            XCTAssertEqual(commands, [.openAutomation(shown)], caption)
        }
    }

    func testLinkButtonRefusedByPolicyIsDisabled() throws {
        let actions = #"[{"label":"Open Board","kind":"link","open":"watchtower-nav://hidden","primary":true},"#
            + #"{"label":"Open Home","kind":"link","open":"watchtower-nav://home"}]"#
        let sut = pane(card(actions: actions), navScreens: ["home"])

        XCTAssertTrue(try sut.inspect().find(button: "Open Board").isDisabled())
        XCTAssertFalse(try sut.inspect().find(button: "Open Home").isDisabled())
    }

    func testFirstActionPrimaryUnlessFalse() throws {
        let primary = pane(card(actions: twoActions))
        XCTAssertTrue(try primary.inspect().find(button: "Move to Backlog").buttonStyle() is KitPrimaryButtonStyle)
        XCTAssertTrue(try primary.inspect().find(button: "Draft a Reply").buttonStyle() is KitSecondaryButtonStyle)

        let notPrimary = #"[{"label":"Move to Backlog","kind":"reply","reply":"backlog","primary":false},"#
            + #"{"label":"Draft a Reply","kind":"chat","chat":"Draft a reply"}]"#
        let quiet = pane(card(actions: notPrimary))
        XCTAssertTrue(try quiet.inspect().find(button: "Move to Backlog").buttonStyle() is KitSecondaryButtonStyle)
        XCTAssertTrue(try quiet.inspect().find(button: "Draft a Reply").buttonStyle() is KitSecondaryButtonStyle)
    }

    func testNothingSelectedSaysSo() throws {
        let sut = InboxReadingPane(item: nil, navScreens: []) { _ in }
        XCTAssertNoThrow(try sut.inspect().find(text: "Select a card"))
    }
}

/// A due reminder in the reading pane links the Slack message it was set
/// from — never the raw `<channel_id>@<message_ts>` ref, and nothing at all
/// without one.
@MainActor
final class InboxReminderPaneTests: XCTestCase {
    private func reminderPane(messageRef: String) -> InboxReadingPane {
        let reminder = Reminder(row: Row(["id": 1, "message_ref": messageRef, "note": "Ping Ann",
                                          "remind_at": "2000-01-01T00:00:00Z", "status": "pending"]))
        return InboxReadingPane(item: .reminder(reminder), navScreens: []) { _ in }
    }

    func testReminderWithAMessageRefLinksTheSlackMessage() throws {
        let sut = reminderPane(messageRef: "1:C0ABC@1740000000.5")
        let link = try sut.inspect().find(ViewType.Link.self)
        XCTAssertEqual(try link.url().absoluteString, "https://slack.com/archives/C0ABC/p17400000005")
        XCTAssertThrowsError(try sut.inspect().find(text: "1:C0ABC@1740000000.5"), "the raw ref is not shown")
    }

    func testReminderWithAnEmptyMessageRefShowsNoLink() throws {
        let sut = reminderPane(messageRef: "")
        XCTAssertNoThrow(try sut.inspect().find(text: "Ping Ann"))
        XCTAssertThrowsError(try sut.inspect().find(ViewType.Link.self))
        XCTAssertNoThrow(try sut.inspect().find(button: "Done"))
        XCTAssertNoThrow(try sut.inspect().find(button: "Snooze 1h"))
    }
}

/// An agent press goes out with the workbench it resolved; one that names no
/// workbench waits for the owner's pick (a popover) instead.
@MainActor
final class InboxAgentPressTests: XCTestCase {
    private let workbenches = [Int64(3), 4].map { (id: Int64) in
        Workbench(row: Row(["id": id, "name": "acme-\(id)", "folder_path": "/acme/\(id)"]))
    }

    private func card(workbenchID: Int64?, actions: String = "[]") -> AutomationOutputCard {
        AutomationOutputCard(id: 5, automationID: 2, automationName: "Issue triage", runID: 212, title: "ACME-482",
                             body: "", priority: "high", createdAt: Date(timeIntervalSinceReferenceDate: 800_000_000),
                             actionsJSON: actions, workbenchID: workbenchID)
    }

    private func buttons(_ card: AutomationOutputCard, onCommand: @escaping (InboxCardCommand) -> Void)
        -> InboxCardButtons {
        InboxCardButtons(card: card, navScreens: [], onCommand: onCommand, workbenches: workbenches)
    }

    func testResolvedWorkbenchGoesOutAsItsID() throws {
        var commands: [InboxCardCommand] = []
        let own = card(workbenchID: 3, actions: #"[{"label":"Ask","kind":"agent","agent":{"task":"Fix","workbench":"ACME-4"}}]"#)
        let sut = buttons(own) { commands.append($0) }

        try sut.inspect().find(button: "Hand to Agent…").tap()
        try sut.inspect().find(button: "Ask").tap()

        XCTAssertEqual(commands, [
            .agent(card: own, task: InboxCardTexts.handToAgentTask(own), workbench: .id(3)),
            .agent(card: own, task: "Fix", workbench: .id(4))
        ])
    }

    func testUnresolvedPressWaitsForThePick() throws {
        var commands: [InboxCardCommand] = []
        let sut = buttons(card(workbenchID: nil)) { commands.append($0) }

        try sut.inspect().find(button: "Hand to Agent…").tap()

        XCTAssertEqual(commands, [], "the picker opens; nothing is handed over yet")
    }
}

/// A pending `save_automation` proposal in the reading pane: its summary,
/// **Open Draft** (the screen's one prominent action) and **Reject**.
@MainActor
final class SaveAutomationProposalPaneTests: XCTestCase {
    private func proposal(status: String = "pending") throws -> AgentAction {
        let args: [String: Any] = [
            "path": "/acme/automations/mail-digest.md", "name": "Mail digest", "slug": "mail-digest",
            "trigger_kind": "schedule", "trigger_spec": ["schedule": "0 9 * * 1-5"], "is_new": true,
            "permissions": ["gmail:read@work", "llm:light", "slack:read@acme"], "workbench_id": 3,
            "recipe_text": "---\nname: Mail digest\n---\n"
        ]
        let json = try XCTUnwrap(String(data: try JSONSerialization.data(withJSONObject: args), encoding: .utf8))
        return AgentAction(row: Row(["id": 8, "tool": "save_automation", "args_json": json, "status": status,
                                     "reason": "Skip newsletters"]))
    }

    func testPaneShowsTheSummaryAndItsTwoButtons() throws {
        var opened: [SaveAutomationCardModel] = []
        var rejected = 0
        let sut = SaveAutomationProposalPane(action: try proposal(), workbenchName: { $0 == 3 ? "acme" : nil },
                                             onOpenDraft: { opened.append($0) }, onReject: { rejected += 1 })

        for text in ["Save automation Mail digest", "acme", "Every weekday at 09:00",
                     "Read mail in work (Gmail), Use the light model and 1 more", "Skip newsletters"] {
            XCTAssertNoThrow(try sut.inspect().find(text: text), text)
        }
        XCTAssertTrue(try sut.inspect().find(button: "Open Draft").buttonStyle() is KitPrimaryButtonStyle)
        try sut.inspect().find(button: "Open Draft").tap()
        try sut.inspect().find(button: "Reject").tap()
        XCTAssertEqual(opened.map(\.recipeText), ["---\nname: Mail digest\n---\n"])
        XCTAssertEqual(rejected, 1)
    }

    func testReadingPaneUsesItForAPendingSaveOnly() throws {
        let pane: (AgentAction) -> SaveAutomationProposalPane = { action in
            SaveAutomationProposalPane(action: action, workbenchName: { _ in nil }, onOpenDraft: { _ in }, onReject: {})
        }
        let pending = InboxReadingPane(item: .proposal(try proposal()), navScreens: [], onCommand: { _ in },
                                       saveProposal: pane)
        XCTAssertNoThrow(try pending.inspect().find(SaveAutomationProposalPane.self))

        let decided = InboxReadingPane(item: .proposal(try proposal(status: "rejected")), navScreens: [],
                                       onCommand: { _ in }, saveProposal: pane)
        XCTAssertThrowsError(try decided.inspect().find(SaveAutomationProposalPane.self),
                             "a decided proposal shows its card and result")
    }
}
