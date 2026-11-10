import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport
import DesignKit
import SwiftUI
import ViewInspector

/// Reply from a row (inbox builder B Task 18, asks #445 and #451): which
/// items have Reply…, the one `actions propose` call a press makes (never
/// `--approve`), the composer's refusal, the waiting caption, the recipe's
/// `reply` suppressed exactly when the native one exists, and the Messages
/// entry's card while it stands in for Waiting for me.
@MainActor
final class InboxReplyTests: XCTestCase {
    private var manager: DatabaseManager!
    private var path: String!
    private var pool: DatabasePool { manager.dbPool }

    override func setUp() async throws {
        (manager, path) = try TestDatabase.createDatabaseManager()
    }

    override func tearDown() async throws {
        manager = nil
        TestDatabase.cleanup(path: path)
    }

    private static let slackLink = "https://acme.slack.com/archives/C001/p1700000000000100"
    private static let proposed = Data(#"{"ok":true,"action":{"id":7},"applied_ok":false,"error":""}"#.utf8)

    private func strip(_ runner: FakeCLIRunner = FakeCLIRunner(stdout: proposed)) async -> ActionStripViewModel {
        let vm = ActionStripViewModel(dbPool: pool, cliRunner: runner)
        await vm.refresh()
        return vm
    }

    private func slackItem() async throws -> Int64 {
        try await pool.write { db in
            try TestDatabase.insertInboxItem(db, channelID: "1:C001", triggerType: "mention", permalink: Self.slackLink)
        }
    }

    private func item(
        trigger: String, channelID: String = "1:C001", permalink: String = slackLink
    ) -> InboxItem {
        InboxItem(row: Row([
            "id": 42, "trigger_type": trigger, "channel_id": channelID, "permalink": permalink
        ] as [String: (any DatabaseValueConvertible)?]))
    }

    private func args(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    private func type(_ text: String, on id: Int64, _ handler: InboxRowActionHandler) {
        let ref = InboxRef(kind: .inboxItem, id: id)
        XCTAssertTrue(handler.pressNow(.reply, on: ref))
        XCTAssertTrue(handler.pressNow(.replyChanged(text), on: ref))
    }

    // MARK: - Which items

    func testReplyShownPerTriggerType() {
        for trigger in ["mention", "dm", "thread_reply", "reaction"] {
            XCTAssertEqual(InboxReplyPolicy.tool(for: item(trigger: trigger)), .slack, trigger)
        }
        for trigger in ["jira_assigned", "jira_comment_mention"] {
            XCTAssertEqual(InboxReplyPolicy.tool(for: item(trigger: trigger, channelID: "ABC-7")), .jira, trigger)
        }
        for trigger in ["linear_assigned", "linear_comment_mention"] {
            XCTAssertEqual(InboxReplyPolicy.tool(for: item(trigger: trigger, channelID: "ENG-7")), .linear, trigger)
        }
        XCTAssertNil(InboxReplyPolicy.tool(for: item(trigger: "email_received")), "mail has no write path")
        XCTAssertNil(InboxReplyPolicy.tool(for: item(trigger: "mention", permalink: "")), "no permalink, no Reply")
        XCTAssertNil(InboxReplyPolicy.tool(for: item(trigger: "jira_assigned", channelID: "")), "no key, no Reply")
        XCTAssertNil(InboxReplyPolicy.tool(for: item(trigger: "linear_assigned", channelID: "")), "no key, no Reply")
    }

    func testArgsBoundToTheItemsPlace() throws {
        let slackArgs = InboxReplyPolicy.args(for: item(trigger: "dm"), text: "On it", host: "Waiting for me")
        let slack = try args(XCTUnwrap(slackArgs))
        XCTAssertEqual(slack["channel"] as? String, Self.slackLink)
        XCTAssertEqual(slack["account_id"] as? Int, 1)
        XCTAssertEqual(slack["text"] as? String, "On it")
        XCTAssertEqual(slack["reason"] as? String, "Reply from Waiting for me")
        XCTAssertEqual(slack.count, 4)

        let jira = try args(XCTUnwrap(InboxReplyPolicy.args(
            for: item(trigger: "jira_comment_mention", channelID: "ABC-7"), text: "On it", host: "Messages")))
        XCTAssertEqual(jira as NSDictionary, ["key": "ABC-7", "body": "On it", "reason": "Reply from Messages"])

        let linear = try args(XCTUnwrap(InboxReplyPolicy.args(
            for: item(trigger: "linear_assigned", channelID: "ENG-7"), text: "On it", host: "Release pings")))
        XCTAssertEqual(linear as NSDictionary, ["key": "ENG-7", "body": "On it", "reason": "Reply from Release pings"])

        XCTAssertNil(InboxReplyPolicy.args(for: item(trigger: "email_received"), text: "On it", host: "Messages"))
    }

    // MARK: - The row

    func testRowDrawsReplyForASlackItemNotForMail() async throws {
        let slack = try await slackItem()
        let mail = try await pool.write { db in
            try TestDatabase.insertInboxItem(db, channelID: "mail", messageTS: "2", triggerType: "email_received",
                                             permalink: "https://mail.example.com/m/1")
        }
        let vm = await strip()
        let hooks = InboxRefHooks(vm: vm, navScreens: [])
        XCTAssertEqual(hooks.content(InboxRef(kind: .inboxItem, id: slack), .inbox)?.hasReply, true)
        XCTAssertEqual(hooks.content(InboxRef(kind: .inboxItem, id: mail), .inbox)?.hasReply, false)
    }

    func testRecipeReplySuppressedExactlyWhenTheNativeReplyExists() async throws {
        let slack = try await slackItem()
        let mail = try await pool.write { db in
            try TestDatabase.insertInboxItem(db, channelID: "mail", messageTS: "2", triggerType: "email_received",
                                             permalink: "https://mail.example.com/m/1")
        }
        let vm = await strip()
        let hooks = InboxRefHooks(vm: vm, navScreens: []).hooks
        XCTAssertEqual(hooks.nativeKinds(ArtifactRef(kind: .inboxItem, id: slack)), [.open, .chat, .agent, .reply])
        XCTAssertEqual(hooks.nativeKinds(ArtifactRef(kind: .inboxItem, id: mail)), [.open, .chat, .agent],
                       "a mail item keeps the recipe's reply")
    }

    func testOneProposeCallPerPressNeverApprove() async throws {
        let id = try await slackItem()
        let runner = FakeCLIRunner(stdout: Self.proposed)
        let vm = await strip(runner)
        let handler = InboxRowActionHandler(vm: vm, replyHost: "Waiting for me")
        type("  Tagged an hour ago.  ", on: id, handler)
        XCTAssertEqual(vm.replyState(Int(id)), .composing(text: "  Tagged an hour ago.  ", error: nil))

        await handler.press(.proposeReply, on: InboxRef(kind: .inboxItem, id: id))

        XCTAssertEqual(runner.invocations.count, 1)
        let argv = try XCTUnwrap(runner.invocations.first)
        XCTAssertEqual(Array(argv.prefix(8)), ["actions", "propose", "--tool", "send_slack_message",
                                               "--surface", "inbox", "--context", "inbox_item:\(id)"])
        XCTAssertFalse(argv.contains("--approve"), "a reply is approved in Needs approval only")
        XCTAssertEqual(argv.last, "--json")
        let sent = try args(XCTUnwrap(argv.firstIndex(of: "--args").map { argv[$0 + 1] }))
        XCTAssertEqual(sent["text"] as? String, "Tagged an hour ago.")
        XCTAssertEqual(sent["reason"] as? String, "Reply from Waiting for me")
        XCTAssertNil(vm.replyDrafts[Int(id)], "the composer closes once proposed")
    }

    /// Typing or Cancel while the propose runs changes nothing: the text
    /// that went to Needs approval is the text the composer showed.
    func testComposerHoldsStillWhileTheProposeRuns() async throws {
        let id = try await slackItem()
        let runner = FakeCLIRunner(stdout: Self.proposed)
        let vm = await strip(runner)
        let handler = InboxRowActionHandler(vm: vm)
        type("On it", on: id, handler)
        let seen = SeenTexts()
        runner.onRun = { _ in
            await MainActor.run {
                vm.editReply(Int(id), text: "On it, and more")
                vm.cancelReply(Int(id))
                seen.value.append(vm.replyDrafts[Int(id)]?.text)
            }
        }

        await handler.press(.proposeReply, on: InboxRef(kind: .inboxItem, id: id))

        XCTAssertEqual(seen.value, ["On it"], "no edit and no Cancel while the propose runs")
        XCTAssertNil(vm.replyDrafts[Int(id)], "proposed: the composer closes")
    }

    func testComposerFieldAndCancelWaitWhileBusy() throws {
        let busy = InboxRowActionsContent(
            kind: .inboxItem(openLabel: nil, openEnabled: false, canReply: true, showsHandToAgent: true),
            state: .busy, reply: .composing(text: "On it", error: nil))
        let footer = InboxRowActionsFooter(content: busy)
        XCTAssertTrue(try footer.inspect().find(ViewType.TextField.self).isDisabled())
        XCTAssertTrue(try footer.inspect().find(button: "Cancel").isDisabled())
        XCTAssertTrue(try footer.inspect().find(button: "Propose Reply").isDisabled())

        var idle = busy
        idle.state = .idle
        let open = InboxRowActionsFooter(content: idle)
        XCTAssertFalse(try open.inspect().find(ViewType.TextField.self).isDisabled())
        XCTAssertFalse(try open.inspect().find(button: "Cancel").isDisabled())
    }

    func testCancelAndEmptyTextProposeNothing() async throws {
        let id = try await slackItem()
        let runner = FakeCLIRunner(stdout: Self.proposed)
        let vm = await strip(runner)
        let handler = InboxRowActionHandler(vm: vm)
        let ref = InboxRef(kind: .inboxItem, id: id)

        type("   ", on: id, handler)
        await handler.press(.proposeReply, on: ref)
        XCTAssertTrue(runner.invocations.isEmpty, "blank text proposes nothing")

        XCTAssertTrue(handler.pressNow(.cancelReply, on: ref))
        XCTAssertNil(vm.replyState(Int(id)))
        await handler.press(.proposeReply, on: ref)
        XCTAssertTrue(runner.invocations.isEmpty, "a closed composer proposes nothing")
    }

    func testRefusalKeepsTheComposerWithTheCLIsMessage() async throws {
        let id = try await slackItem()
        let runner = FakeCLIRunner(error: CLIRunnerError.nonZeroExit(
            code: 1, stderr: "Error: a reply to this item is already waiting for approval (#3)\n"))
        let vm = await strip(runner)
        let handler = InboxRowActionHandler(vm: vm)
        type("On it", on: id, handler)

        await handler.press(.proposeReply, on: InboxRef(kind: .inboxItem, id: id))

        XCTAssertEqual(runner.invocations.count, 1, "never retried")
        XCTAssertEqual(vm.replyState(Int(id)), .composing(
            text: "On it", error: "a reply to this item is already waiting for approval (#3)"))
    }

    func testUnexpectedAnswerIsAFailure() async throws {
        let id = try await slackItem()
        let vm = await strip(FakeCLIRunner(stdout: Data("proposed".utf8)))
        let handler = InboxRowActionHandler(vm: vm)
        type("On it", on: id, handler)

        await handler.press(.proposeReply, on: InboxRef(kind: .inboxItem, id: id))

        XCTAssertEqual(vm.replyState(Int(id)), .composing(text: "On it", error: "Unexpected answer from watchtower"))
    }

    /// Only an answer with the proposal's id (`action.id`) is a proposal:
    /// `{}` or any other object is a failure, never success.
    func testAnswerWithoutTheActionIDIsAFailure() async throws {
        let id = try await slackItem()
        let unexpected = "Unexpected answer from watchtower"
        let answers: [(String, String?)] = [
            ("{}", unexpected),
            (#"{"foo":1}"#, unexpected),
            (#"{"ok":true,"action":{}}"#, unexpected),
            (#"{"ok":false,"error":"no channel"}"#, "no channel"),
            (#"{"ok":false}"#, "The reply was not proposed."),
            (#"{"ok":true,"action":{"id":7},"applied_ok":false,"error":""}"#, nil)
        ]
        for (answer, failure) in answers {
            let vm = await strip(FakeCLIRunner(stdout: Data(answer.utf8)))
            let handler = InboxRowActionHandler(vm: vm)
            type("On it", on: id, handler)
            await handler.press(.proposeReply, on: InboxRef(kind: .inboxItem, id: id))
            XCTAssertEqual(vm.replyDrafts[Int(id)]?.error, failure, answer)
            XCTAssertEqual(vm.replyDrafts[Int(id)] == nil, failure == nil, answer)
        }
    }

    func testPendingProposalShowsTheCaptionAndDisablesReply() async throws {
        let id = try await slackItem()
        try await pool.write { db in
            _ = try TestDatabase.insertAgentAction(
                db, tool: "send_slack_message", external: true, surface: "inbox",
                contextType: "inbox_item", contextID: String(id), status: "pending")
        }
        let vm = await strip()
        let content = try XCTUnwrap(InboxRefHooks(vm: vm, navScreens: []).content(
            InboxRef(kind: .inboxItem, id: id), .inbox))
        XCTAssertEqual(content.reply, .waiting, "Reply waiting for approval; Reply… disabled")
        vm.startReply(Int(id))
        XCTAssertNil(vm.replyDrafts[Int(id)], "one reply per item at a time")
    }

    func testRejectedReplyLeavesReplyOpenAgain() async throws {
        let id = try await slackItem()
        try await pool.write { db in
            _ = try TestDatabase.insertAgentAction(
                db, tool: "send_slack_message", external: true, surface: "inbox",
                contextType: "inbox_item", contextID: String(id), status: "rejected")
        }
        let vm = await strip()
        XCTAssertNil(vm.replyState(Int(id)))
    }

    func testDraftSurvivesARefreshAndLeavesWithItsRow() async throws {
        let id = try await slackItem()
        let vm = await strip()
        type("Half a thought", on: id, InboxRowActionHandler(vm: vm))
        // The view goes away and comes back: the draft lives on the strip.
        await vm.refresh()
        XCTAssertEqual(vm.replyState(Int(id)), .composing(text: "Half a thought", error: nil))

        try await pool.write { db in
            try db.execute(sql: "UPDATE inbox_items SET status = 'resolved' WHERE id = ?", arguments: [id])
        }
        await vm.refresh()
        XCTAssertNil(vm.replyDrafts[Int(id)], "the draft goes with its row")
    }

    /// A propose that timed out may still have landed: once the read shows
    /// that reply waiting, the old draft goes, and never comes back with its
    /// error after the reply is approved and sent.
    func testDraftGoesOnceItsReplyIsWaiting() async throws {
        let id = try await slackItem()
        let vm = await strip(FakeCLIRunner(error: CancellationError()))
        let handler = InboxRowActionHandler(vm: vm)
        type("On it", on: id, handler)
        await handler.press(.proposeReply, on: InboxRef(kind: .inboxItem, id: id))
        XCTAssertNotNil(vm.replyDrafts[Int(id)]?.error, "the timeout stays in the composer")

        let action = try await pool.write { db in
            try TestDatabase.insertAgentAction(
                db, tool: "send_slack_message", external: true, surface: "inbox",
                contextType: "inbox_item", contextID: String(id), status: "pending")
        }
        await vm.refresh()
        XCTAssertEqual(vm.replyState(Int(id)), .waiting)
        XCTAssertNil(vm.replyDrafts[Int(id)], "the reply that landed replaces the draft")

        try await pool.write { db in
            try db.execute(sql: "UPDATE agent_actions SET status = 'applied' WHERE id = ?", arguments: [action])
        }
        await vm.refresh()
        XCTAssertNil(vm.replyState(Int(id)), "no stale composer once the reply was sent")
    }

    // MARK: - The host

    func testReplyReasonNamesHost() {
        func card(_ title: String) -> InboxListItem {
            .output(AutomationOutputCard(id: 1, automationID: 2, automationName: "A", runID: 3, title: title, body: "",
                                         priority: "medium", createdAt: Date()))
        }
        XCTAssertEqual(InboxRefHooks.replyHost(card("Waiting for me")), "Waiting for me")
        XCTAssertEqual(InboxRefHooks.replyHost(card("Release pings")), "Release pings")
        XCTAssertEqual(InboxRefHooks.replyHost(nil), "Messages")
        XCTAssertEqual(InboxReplyPolicy.reason(host: "Messages"), "Reply from Messages")
    }

    // MARK: - The Messages entry standing in for Waiting for me

    private func waitingForMe(runStatus: String?) async throws {
        try await pool.write { db in
            let id = try TestDatabase.insertAutomation(db, slug: "waiting-for-me")
            try db.execute(sql: """
                UPDATE automations SET origin = 'builtin', builtin_id = 'waiting-for-me', path = 'builtin:waiting-for-me'
                WHERE id = ?
                """, arguments: [id])
            if let runStatus {
                _ = try TestDatabase.insertAutomationRun(db, automationID: id, status: runStatus)
            }
        }
    }

    private func messageReply(_ vm: ActionStripViewModel, _ id: Int64) throws -> InboxRowActionsContent? {
        let row = try XCTUnwrap(vm.feed.messages.first { Int64($0.item.id) == id })
        return InboxRefHooks(vm: vm, navScreens: []).messageReply(row)
    }

    func testReplyShownOnMessagesStandInBeforeFirstRun() async throws {
        let id = try await slackItem()
        try await waitingForMe(runStatus: nil)
        let vm = await strip()
        XCTAssertEqual(try messageReply(vm, id)?.hasReply, true)
    }

    func testReplyShownOnMessagesStandInAfterFailedRun() async throws {
        let id = try await slackItem()
        try await waitingForMe(runStatus: "failed")
        let vm = await strip()
        XCTAssertEqual(try messageReply(vm, id)?.hasReply, true)
    }

    func testReplyGoneFromStandInOnceWaitingForMeSucceeds() async throws {
        let id = try await slackItem()
        try await waitingForMe(runStatus: "succeeded")
        let vm = await strip()
        XCTAssertNil(try messageReply(vm, id), "the stand-in left; Reply is on Waiting for me's rows")
    }

    /// No `watchtower` binary: the stand-in card's Reply… is off like a row's, and says why.
    func testStandInReplyFollowsTheMissingCLIRule() async throws {
        let id = try await slackItem()
        try await waitingForMe(runStatus: nil)
        // Labeled: a trailing closure would bind to `automationsWake`.
        // swiftlint:disable:next trailing_closure
        let vm = ActionStripViewModel(dbPool: pool, findCLI: { nil })
        await vm.refresh()
        let reply = try XCTUnwrap(try messageReply(vm, id))
        XCTAssertTrue(reply.isOff(.reply))
        XCTAssertTrue(reply.showsCLIMissingLine)

        let row = try XCTUnwrap(vm.feed.messages.first { Int64($0.item.id) == id })
        let card = InboxMessagePane(row: row, onDone: {}, onHide: {}, onSnooze: { _ in }, onCommand: { _ in },
                                    reply: reply)
        XCTAssertTrue(try card.inspect().find(button: "Reply…").isDisabled())
        XCTAssertNoThrow(try card.inspect().find(text: InboxRowActionsContent.cliMissingMessage))
    }

    func testStandInCardHasNoReplyForMail() async throws {
        let mail = try await pool.write { db in
            try TestDatabase.insertInboxItem(db, channelID: "mail", triggerType: "email_received",
                                             permalink: "https://mail.example.com/m/1")
        }
        let vm = await strip()
        XCTAssertNil(try messageReply(vm, mail))
    }
}

/// What the composer held, read from inside a fake CLI run (main actor only).
private final class SeenTexts: @unchecked Sendable {
    var value: [String?] = []
}
