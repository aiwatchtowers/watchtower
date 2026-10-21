import XCTest
import GRDB
import SwiftUI
import ViewInspector
@testable import WatchtowerDesktop
@testable import WatchtowerCore
import WatchtowerTestSupport

/// A message card in the Inbox reading pane (C1 §6.2, R5): who, where, the
/// text as plain text, Open in <source> only with a permalink, Discuss in
/// Chat, Done, Hide and Snooze ▾; a channel item lists each folded message.
@MainActor
final class InboxMessagePaneTests: XCTestCase {
    private func row(
        trigger: String = "mention",
        snippet: String = "Can you review the launch plan?",
        permalink: String = "https://example.com/archives/C01/p1",
        mentions: String? = nil,
        earlier: Int = 0,
        senderNames: [String: String] = [:]
    ) -> HomeFeedInboxRow {
        var values: [String: (any DatabaseValueConvertible)?] = [
            "id": 9, "trigger_type": trigger, "snippet": snippet, "permalink": permalink, "channel_id": "acme:C01",
            "mentions_earlier": earlier
        ]
        if let mentions { values["mentions"] = mentions }
        return HomeFeedInboxRow(item: InboxItem(row: Row(values)), stamp: Date(), who: "Ann", whereText: "#eng",
                                senderNames: senderNames)
    }

    private func pane(
        _ row: HomeFeedInboxRow,
        onSnooze: @escaping (String) -> Void = { _ in },
        onCommand: @escaping (InboxCardCommand) -> Void = { _ in }
    ) -> InboxMessagePane {
        InboxMessagePane(row: row, onDone: {}, onHide: {}, onSnooze: onSnooze, onCommand: onCommand)
    }

    func testButtonsForASlackMention() throws {
        var snoozed: [String] = []
        var commands: [InboxCardCommand] = []
        let shown = row()
        let sut = pane(shown, onSnooze: { snoozed.append($0) }, onCommand: { commands.append($0) })

        for label in ["Open in Slack", "Discuss in Chat", "Done", "Hide"] {
            XCTAssertNoThrow(try sut.inspect().find(button: label), label)
        }
        let menu = try sut.inspect().find(ViewType.Menu.self)
        XCTAssertEqual(try menu.labelView().text().string(), "Snooze")
        for (label, duration) in [("Tomorrow", "1d"), ("In 3 days", "3d"), ("Next week", "1w")] {
            try menu.find(button: label).tap()
            XCTAssertEqual(snoozed.last, duration, label)
        }

        try sut.inspect().find(button: "Open in Slack").tap()
        try sut.inspect().find(button: "Discuss in Chat").tap()
        let subject = InboxCardSubject(message: shown)
        XCTAssertEqual(commands, [
            .openLink(try XCTUnwrap(URL(string: "https://example.com/archives/C01/p1"))),
            .chat(subject, message: InboxCardTexts.discussMessage(subject))
        ])
    }

    func testOpenButtonFollowsTheSource() throws {
        for (trigger, label) in [("jira_assigned", "Open in Jira"), ("jira_comment_mention", "Open in Jira"),
                                 ("linear_assigned", "Open in Linear"), ("email_received", "Open in Mail"),
                                 ("dm", "Open in Slack")] {
            let sut = pane(row(trigger: trigger))
            XCTAssertNoThrow(try sut.inspect().find(button: label), trigger)
        }
    }

    func testNoOpenButtonWithoutPermalink() throws {
        let sut = pane(row(permalink: ""))
        for label in ["Open in Slack", "Open in Jira", "Open in Linear", "Open in Mail", "Open source"] {
            XCTAssertThrowsError(try sut.inspect().find(button: label), label)
        }
        XCTAssertNoThrow(try sut.inspect().find(button: "Discuss in Chat"))
    }

    func testAccumulatedChannelItemListsEachMention() throws {
        let mentions = #"[{"ts":"1.1","sender":"acme:U01","trigger":"mention","text":"First ask","#
            + #""permalink":"https://example.com/archives/C01/p11"},"#
            + #"{"ts":"1.2","sender":"acme:U02","trigger":"mention","text":"Second ask","permalink":""}]"#
        var commands: [InboxCardCommand] = []
        let sut = pane(row(mentions: mentions, earlier: 3, senderNames: ["acme:U01": "Ann"])) { commands.append($0) }

        XCTAssertNoThrow(try sut.inspect().find(text: "5 mentions"))
        XCTAssertNoThrow(try sut.inspect().find(text: "+3 earlier"))
        XCTAssertNoThrow(try sut.inspect().find(text: "Ann: First ask"))
        XCTAssertNoThrow(try sut.inspect().find(text: "Second ask"), "an unnamed sender shows the bare text")
        XCTAssertThrowsError(try sut.inspect().find(text: "acme:U02: Second ask"), "never a raw id")

        let opens = try sut.inspect().findAll(ViewType.Button.self).filter { try $0.labelView().text().string() == "Open" }
        XCTAssertEqual(opens.count, 1, "only the mention with its own link")
        try opens[0].tap()
        XCTAssertEqual(commands, [.openLink(try XCTUnwrap(URL(string: "https://example.com/archives/C01/p11")))])
    }

    /// Slack text is someone else's: shown as typed, never as a live link.
    func testMessageTextIsPlain() throws {
        let text = "Read [this](https://evil.example.com) **now**"
        let sut = pane(row(snippet: text))
        XCTAssertNoThrow(try sut.inspect().find(text: text))
        XCTAssertThrowsError(try sut.inspect().find(ViewType.Link.self))
    }

    // MARK: - The split view's routes

    /// Done, Hide and a Snooze choice on the shown message run
    /// `watchtower inbox resolve|dismiss|snooze` for that row (R5).
    func testDoneHideAndSnoozeRouteToTheInboxCLI() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let id = try await pool.write { db in try TestDatabase.insertInboxItem(db, snippet: "Review please") }
        let suite = "InboxMessagePaneTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let runner = FakeCLIRunner()
        let vm = ActionStripViewModel(dbPool: pool, cliRunner: runner, defaults: defaults)
        await vm.refresh()
        vm.selection = .message(Int(id))
        let sut = InboxSplitView(
            vm: vm, proposalCard: card,
            onCardAction: { _ in }, emptyList: { EmptyView() })

        let presses: [(press: () throws -> Void, args: [String])] = [
            ({ try sut.inspect().find(button: "Done").tap() }, ["inbox", "resolve", "\(id)"]),
            ({ try sut.inspect().find(button: "Hide").tap() }, ["inbox", "dismiss", "\(id)"]),
            ({ try sut.inspect().find(ViewType.Menu.self).find(button: "Next week").tap() },
             ["inbox", "snooze", "\(id)", "1w"])
        ]
        for (index, step) in presses.enumerated() {
            let ran = expectation(description: step.args.joined(separator: " "))
            runner.onRun = { _ in ran.fulfill() }
            try step.press()
            await fulfillment(of: [ran], timeout: 5)
            XCTAssertEqual(runner.invocations.count, index + 1)
            XCTAssertEqual(runner.invocations.last, step.args)
            // The card's buttons wait for its press; the next press comes after.
            for _ in 0..<500 where vm.isWriting(.message(Int(id))) {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertFalse(vm.isWriting(.message(Int(id))))
        }
    }

    private func card(_ action: AgentAction) -> AgentActionCardView {
        AgentActionCardView(action: action, inFlight: false, onApprove: {}, onReject: {}, onRetry: {})
    }
}
