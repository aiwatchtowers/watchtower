import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// Native row actions for a `ref` (inbox builder B Task 13, spec "Native
/// row actions for a `ref`"): each kind draws today's card buttons, presses
/// call today's functions only, a failed press stays on its row with a
/// Retry that repeats it, and a vanished record leaves quietly.
@MainActor
final class InboxRowActionsTests: XCTestCase {
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

    private struct Failure: LocalizedError {
        var errorDescription: String? { "the watchtower CLI timed out" }
    }

    private static let okEnvelope = Data(#"{"ok":true,"applied_ok":true,"error":""}"#.utf8)

    private func strip(_ runner: FakeCLIRunner = FakeCLIRunner()) async -> ActionStripViewModel {
        let vm = ActionStripViewModel(dbPool: pool, cliRunner: runner)
        await vm.refresh()
        return vm
    }

    private func hooks(_ vm: ActionStripViewModel) -> InboxRefHooks {
        InboxRefHooks(vm: vm, navScreens: [])
    }

    private func handler(
        _ vm: ActionStripViewModel,
        ideas: IdeasViewModel? = nil,
        onCommand: @escaping (InboxCardCommand) -> Void = { _ in },
        onEdit: @escaping (Int64) -> Void = { _ in }
    ) -> InboxRowActionHandler {
        InboxRowActionHandler(vm: vm, ideas: ideas, onCommand: onCommand, onEditAction: onEdit)
    }

    private func insertReminder(remindAt: String = "2000-01-01T00:00:00Z") throws -> Int64 {
        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO reminders (message_ref, note, remind_at, status)
                VALUES ('C1@1', 'call back', ?, 'pending')
                """, arguments: [remindAt])
            return db.lastInsertedRowID
        }
    }

    private func failUpdates(on table: String) throws {
        try pool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_\(table) BEFORE UPDATE ON \(table)
                BEGIN SELECT RAISE(ABORT, 'disk is busy'); END
                """)
        }
    }

    private func allowUpdates(on table: String) throws {
        try pool.write { db in try db.execute(sql: "DROP TRIGGER fail_\(table)") }
    }

    // MARK: - The drawn set per kind (today's card's buttons)

    func testInboxItemDrawsTheMessageCardsActions() async throws {
        let id = try await pool.write { db in
            try TestDatabase.insertInboxItem(db, triggerType: "mention",
                                             permalink: "https://acme.slack.com/archives/C001/p1700000000000100")
        }
        let vm = await strip()
        let content = try XCTUnwrap(hooks(vm).content(InboxRef(kind: .inboxItem, id: id), .inbox))
        // `InboxMessagePane`: Open in Slack (a permalink), Discuss in Chat,
        // Hand to Agent…, Done, Hide, Snooze ▾; Reply… for a Slack item (Task 18).
        XCTAssertEqual(content.kind, .inboxItem(openLabel: "Open in Slack", openEnabled: true, canReply: true,
                                                showsHandToAgent: true))
        XCTAssertEqual(content.state, .idle)
    }

    func testInboxItemWithoutPermalinkHasNoOpen() async throws {
        let id = try await pool.write { db in try TestDatabase.insertInboxItem(db, permalink: "") }
        let vm = await strip()
        let content = try XCTUnwrap(hooks(vm).content(InboxRef(kind: .inboxItem, id: id), .inbox))
        XCTAssertEqual(content.kind, .inboxItem(openLabel: nil, openEnabled: false, canReply: false,
                                                showsHandToAgent: true))
    }

    func testTrackDrawsTheTrackCardsActions() async throws {
        let (auto, custom, target) = try await pool.write { db in
            let auto = try TestDatabase.insertTrack(db, text: "Release checklist")
            let target = try TestDatabase.insertTarget(db)
            let custom = try TestDatabase.insertTrack(db, text: "Finance refund", linkedTargetID: Int(target))
            try db.execute(sql: "UPDATE tracks SET origin = 'custom' WHERE id = ?", arguments: [custom])
            return (auto, custom, target)
        }
        let vm = await strip()
        XCTAssertEqual(hooks(vm).content(InboxRef(kind: .track, id: auto), .inbox)?.kind,
                       .track(custom: false, linkedTargetID: nil))
        XCTAssertEqual(hooks(vm).content(InboxRef(kind: .track, id: custom), .inbox)?.kind,
                       .track(custom: true, linkedTargetID: Int64(target)))
    }

    func testIdeaDrawsItsVerdictButtons() async throws {
        let id = try await pool.write { db in try TestDatabase.insertIdea(db, status: "proposed") }
        let vm = await strip()
        let idea = try XCTUnwrap(vm.feed.ideas.first { Int64($0.id) == id })
        let content = try XCTUnwrap(hooks(vm).content(InboxRef(kind: .idea, id: id), .inbox))
        XCTAssertEqual(content.kind, .idea(kind: .idea, status: idea.status, awaitsVerdict: idea.awaitsVerdict))
    }

    func testReminderDrawsDoneAndSnooze() async throws {
        let id = try insertReminder()
        let vm = await strip()
        XCTAssertEqual(hooks(vm).content(InboxRef(kind: .reminder, id: id), .inbox)?.kind, .reminder)
    }

    /// The row's buttons for one proposal row, as the Inbox reads it.
    private func actionButtons(
        tool: String = "create_target",
        argsJSON: String = #"{"text":"Call colleague A"}"#,
        status: String = "pending",
        error: String = "",
        sessionHolds: Bool = false
    ) async throws -> [InboxRowActionsContent.ActionButton]? {
        let id = try await pool.write { db in
            try TestDatabase.insertAgentAction(db, tool: tool, argsJSON: argsJSON, status: status, error: error)
        }
        let vm = await strip()
        // Labeled: a trailing closure would read as the row's press.
        // swiftlint:disable:next trailing_closure
        let hooks = InboxRefHooks(vm: vm, navScreens: [], sessionHoldsCall: { _ in sessionHolds })
        guard case let .action(_, buttons)? = hooks.content(InboxRef(kind: .action, id: id), .inbox)?.kind else {
            return nil
        }
        return buttons
    }

    func testActionDrawsApproveOrRetryByStatus() async throws {
        let pending = try await actionButtons()
        XCTAssertEqual(pending, [.approve, .reject, .edit])
        // A failed apply: Retry only, as the card (Go refuses `actions dismiss` on it).
        let failed = try await actionButtons(status: "failed", error: "archived")
        XCTAssertEqual(failed, [.retry])
    }

    /// A target button's failed row with a newer row of the same button: no
    /// Retry on its recipe row, and a Retry press does nothing — the native
    /// card's `offersRetry` gate (Go refuses it with exit 3).
    func testSupersededButtonRowOffersNoRetry() async throws {
        let (older, newer) = try await pool.write { db -> (Int64, Int64) in
            let context = "5:0:0123456789abcdef"
            let older = try TestDatabase.insertAgentAction(
                db, surface: "inbox", contextType: "automation_output", contextID: context, status: "failed",
                error: "archived", createdAt: "2026-11-06T09:00:00Z", decidedAt: "2026-11-06T09:01:00Z")
            let newer = try TestDatabase.insertAgentAction(
                db, surface: "inbox", contextType: "automation_output", contextID: context, status: "pending",
                createdAt: "2026-11-06T09:05:00Z")
            return (older, newer)
        }
        let runner = FakeCLIRunner(stdout: Self.okEnvelope)
        let vm = await strip(runner)
        let content = try XCTUnwrap(hooks(vm).content(InboxRef(kind: .action, id: older), .inbox))
        guard case let .action(_, buttons) = content.kind else { return XCTFail("\(content.kind)") }
        XCTAssertEqual(buttons, [], "no Retry on the superseded row")
        await handler(vm).press(.retry, on: InboxRef(kind: .action, id: older))
        XCTAssertEqual(runner.invocations, [], "nothing run")
        XCTAssertNotNil(hooks(vm).content(InboxRef(kind: .action, id: newer), .inbox))
    }

    /// The row carries the proposal's own words under its line, whatever the
    /// look's row title says, without the tool's name the row or card shows.
    func testActionRowShowsTheProposalsOwnSummary() async throws {
        let id = try await pool.write { db in
            try TestDatabase.insertAgentAction(db, tool: "create_jira_issue",
                                               argsJSON: #"{"project_key":"ACME","issue_type":"Task","summary":"Fix the link"}"#)
        }
        let vm = await strip()
        let hooks = hooks(vm)
        let content = try XCTUnwrap(hooks.content(InboxRef(kind: .action, id: id), .inbox))
        let summary = try XCTUnwrap(content.actionSummary)
        XCTAssertTrue(summary.contains("ACME"), summary)
        XCTAssertTrue(summary.contains("Fix the link"), summary)
        XCTAssertFalse(summary.contains(AgentActionCardView.title(for: vm.feed.proposals[0])), summary)
        XCTAssertEqual(content.state, .idle)
        XCTAssertNotNil(hooks.hooks.nativeFooter(ArtifactRef(kind: .action, id: id), .inbox),
                        "an idle proposal row draws its summary under the line")
    }

    /// A proposal with nothing readable in its args keeps the tool's name as its words.
    func testActionRowSummaryFallsBackToTheToolTitle() async throws {
        let id = try await pool.write { db in
            try TestDatabase.insertAgentAction(db, tool: ConnectorCallProposal.tool, argsJSON: "{}")
        }
        let vm = await strip()
        let action = try XCTUnwrap(vm.feed.proposals.first { $0.id == id })
        XCTAssertEqual(AgentActionCardView.rowSummary(for: action), AgentActionCardView.title(for: action))
    }

    /// A pending `save_automation` is saved in the editor only: Open Draft and Reject, never Approve.
    func testSaveAutomationRowOpensTheDraftNeverApproves() async throws {
        let buttons = try await actionButtons(tool: SaveAutomationCardModel.tool, argsJSON: #"{"path":"a.md"}"#)
        XCTAssertEqual(buttons, [.openDraft, .reject])
    }

    private static let connectorArgs = #"{"server":"claude.ai Gmail","tool":"send","input":{"to":"a@example.com"}}"#

    /// A session call: Approve only while its chat session holds it; Retry never.
    func testConnectorCallApprovesOnlyWhileTheSessionHoldsIt() async throws {
        let held = try await actionButtons(tool: ConnectorCallProposal.tool, argsJSON: Self.connectorArgs,
                                           sessionHolds: true)
        XCTAssertEqual(held, [.approve, .reject, .edit])
        let gone = try await actionButtons(tool: ConnectorCallProposal.tool, argsJSON: Self.connectorArgs)
        XCTAssertEqual(gone, [.reject, .edit])
        let unreadable = try await actionButtons(tool: ConnectorCallProposal.tool, argsJSON: "{}", sessionHolds: true)
        XCTAssertEqual(unreadable, [.reject, .edit])
    }

    func testConnectorCallWithUnknownOutcomeOffersDismissOnly() async throws {
        let buttons = try await actionButtons(tool: ConnectorCallProposal.tool, argsJSON: Self.connectorArgs,
                                              status: "failed", error: ConnectorCallProposal.sessionEndedWhileRunning)
        XCTAssertEqual(buttons, [.dismiss])
    }

    /// A Slack send whose workspace is still to be picked approves on its card only.
    func testSlackSendNeedingAPickHasNoRowApprove() async throws {
        let pick = ##"{"text":"On it","candidates":[{"account_id":1,"workspace":"acme","label":"#general"},"##
            + ##"{"account_id":2,"workspace":"acme-eu","label":"#general"}]}"##
        let picking = try await actionButtons(tool: SlackSendProposal.tool, argsJSON: pick)
        XCTAssertEqual(picking, [.reject, .edit])
        let pinned = ##"{"text":"On it","target":{"account_id":1,"workspace":"acme","label":"#general"}}"##
        let ready = try await actionButtons(tool: SlackSendProposal.tool, argsJSON: pinned)
        XCTAssertEqual(ready, [.approve, .reject, .edit])
    }

    /// An edit the card cannot show is never approved (F7).
    func testUnreadableConfluenceEditHasNoApprove() async throws {
        let buttons = try await actionButtons(tool: AgentActionCardView.confluenceEditTool, argsJSON: "{}")
        XCTAssertEqual(buttons, [.reject, .edit])
    }

    func testOpenDraftOpensTheSaveProposalsDraft() async throws {
        let id = try await pool.write { db in
            try TestDatabase.insertAgentAction(db, tool: SaveAutomationCardModel.tool, argsJSON: #"{"path":"a.md"}"#)
        }
        let runner = FakeCLIRunner()
        let vm = await strip(runner)
        var opened: [Int64] = []
        // Labeled: a trailing closure would bind to `onCommand`.
        // swiftlint:disable:next trailing_closure
        let handler = InboxRowActionHandler(vm: vm, onOpenSaveDraft: { _ in opened.append(id) })
        await handler.press(.openDraft, on: InboxRef(kind: .action, id: id))
        XCTAssertEqual(opened, [id])
        XCTAssertTrue(runner.invocations.isEmpty, "Open Draft writes nothing")
    }

    /// No `watchtower` binary: a row's CLI presses are off and its footer says why (plan "Failure paths").
    func testMissingCLIDisablesRowWritesAndSaysWhy() async throws {
        let id = try await pool.write { db in
            try TestDatabase.insertInboxItem(db, triggerType: "mention",
                                             permalink: "https://acme.slack.com/archives/C001/p1700000000000100")
        }
        let ref = InboxRef(kind: .inboxItem, id: Int64(id))
        // Labeled: a trailing closure would bind to `automationsWake`.
        // swiftlint:disable:next trailing_closure
        let vm = ActionStripViewModel(dbPool: pool, findCLI: { nil })
        await vm.refresh()
        let hooks = hooks(vm)
        let content = try XCTUnwrap(hooks.content(ref, .inbox))
        XCTAssertTrue(content.cliMissing)
        XCTAssertTrue(content.isOff(.done))
        XCTAssertTrue(content.isOff(.hide))
        XCTAssertTrue(content.isOff(.snooze(duration: "")))
        XCTAssertTrue(content.isOff(.reply))
        XCTAssertFalse(content.isOff(.open), "what only opens stays")
        XCTAssertFalse(content.isOff(.discussInChat))
        XCTAssertTrue(content.showsCLIMissingLine)
        XCTAssertNotNil(hooks.hooks.nativeFooter(ArtifactRef(kind: .inboxItem, id: Int64(id)), .inbox),
                        "the footer carries \(InboxRowActionsContent.cliMissingMessage)")
        XCTAssertEqual(InboxRowActionsContent.cliMissingMessage, "The watchtower CLI isn't available")
        XCTAssertFalse(hooks.content(ref, .preview)?.cliMissing ?? true,
                       "a preview draws everything disabled without the line")
        let present = await strip()
        XCTAssertFalse(self.hooks(present).content(ref, .inbox)?.cliMissing ?? true)

        let action = InboxRowActionsContent(kind: .action(summary: "Team: ACME", buttons: [.approve, .reject, .edit]),
                                            cliMissing: true)
        XCTAssertTrue(action.isOff(.approve))
        XCTAssertTrue(action.isOff(.reject))
        XCTAssertFalse(action.isOff(.edit), "Edit… only opens the card")
        XCTAssertTrue(action.showsCLIMissingLine)
    }

    /// A reminder's, a track's and an idea's writes go straight to the
    /// database: they stay on without the CLI, and their rows carry no
    /// missing-CLI line. A custom track's Stop watching runs the CLI.
    func testMissingCLIKeepsDatabaseWritesOn() async throws {
        let id = try insertReminder()
        // Labeled: a trailing closure would bind to `automationsWake`.
        // swiftlint:disable:next trailing_closure
        let vm = ActionStripViewModel(dbPool: pool, findCLI: { nil })
        await vm.refresh()
        let hooks = hooks(vm)
        let reminder = try XCTUnwrap(hooks.content(InboxRef(kind: .reminder, id: id), .inbox))
        XCTAssertTrue(reminder.cliMissing)
        XCTAssertFalse(reminder.isOff(.done))
        XCTAssertFalse(reminder.isOff(.snoozeHour))
        XCTAssertFalse(reminder.isOff(.retryFailedPress))
        XCTAssertFalse(reminder.showsCLIMissingLine)
        XCTAssertNil(hooks.hooks.nativeFooter(ArtifactRef(kind: .reminder, id: id), .inbox),
                     "an idle reminder row draws nothing under its line")
        await InboxRowActionHandler(vm: vm).press(.done, on: InboxRef(kind: .reminder, id: id))
        XCTAssertNil(vm.rowErrors[.reminder(id)], "Done lands without the CLI")
        let status = try await pool.read { db in
            try String.fetchOne(db, sql: "SELECT status FROM reminders WHERE id = ?", arguments: [id])
        }
        XCTAssertEqual(status, "done")

        let auto = InboxRowActionsContent(kind: .track(custom: false, linkedTargetID: nil), cliMissing: true)
        for press: InboxRowPress in [.done, .stopWatching, .makeTask, .retryFailedPress] {
            XCTAssertFalse(auto.isOff(press), "\(press)")
        }
        XCTAssertFalse(auto.showsCLIMissingLine)
        let custom = InboxRowActionsContent(kind: .track(custom: true, linkedTargetID: nil), cliMissing: true)
        XCTAssertFalse(custom.isOff(.done))
        XCTAssertFalse(custom.isOff(.makeTask))
        XCTAssertTrue(custom.isOff(.stopWatching), "a custom track's recipe goes through the CLI")
        XCTAssertTrue(custom.showsCLIMissingLine)
        let idea = InboxRowActionsContent(kind: .idea(kind: .idea, status: .proposed, awaitsVerdict: true),
                                          cliMissing: true)
        for press: InboxRowPress in [.approve, .reject, .makeTask, .notNow(until: ""), .activate, .drop] {
            XCTAssertFalse(idea.isOff(press), "\(press)")
        }
        XCTAssertFalse(idea.showsCLIMissingLine)
    }

    /// A shown row without native content keeps the recipe's own buttons.
    func testRowWithoutNativeContentKeepsTheRecipesButtons() {
        let ref = ArtifactRef(kind: .inboxItem, id: 7)
        let none = InboxRefHooks.make(isShown: { _ in true }, content: { _, _ in nil })
        XCTAssertEqual(none.nativeKinds(ref), [])
        XCTAssertNil(none.nativeActions(ref, .inbox))
        let some = InboxRefHooks.make(isShown: { _ in true }, content: { _, _ in
            InboxRowActionsContent(kind: .inboxItem(openLabel: nil, openEnabled: false, canReply: false,
                                                    showsHandToAgent: true))
        })
        XCTAssertEqual(some.nativeKinds(ref), [.open, .chat, .agent])
    }

    /// An idea row without its `IdeasViewModel` draws its verdicts disabled, not dead.
    func testIdeaVerdictsDisabledWithoutIdeasViewModel() {
        let content = InboxRowActionsContent(kind: .idea(kind: .idea, status: .active, awaitsVerdict: true),
                                             writesUnavailable: true)
        for button in InboxRowActionsContent.ideaButtons(kind: .idea, status: .active, awaitsVerdict: true) {
            XCTAssertTrue(content.isOff(button.press), "\(button)")
        }
        XCTAssertFalse(content.isOff(.open), "the row still opens its card")
    }

    func testIdeaRowWritesUnavailableFollowsIdeasViewModel() async throws {
        let id = try await pool.write { db in try TestDatabase.insertIdea(db, status: "proposed") }
        let vm = await strip()
        var hooks = hooks(vm)
        hooks.ideasAvailable = false
        let ref = InboxRef(kind: .idea, id: id)
        XCTAssertEqual(hooks.content(ref, .inbox)?.writesUnavailable, true)
        hooks.ideasAvailable = true
        XCTAssertEqual(hooks.content(ref, .inbox)?.writesUnavailable, false)
    }

    /// A failed apply with a press error shows one Retry: the row's own.
    func testFailedProposalRowShowsOneRetry() {
        let failed = InboxRowActionsContent(kind: .action(summary: "Create a task", buttons: [.retry]),
                                            state: .failed(message: "the CLI timed out"), failedVerb: "apply")
        XCTAssertFalse(failed.footerOffersRetry)
        let pending = InboxRowActionsContent(kind: .action(summary: "Create a task", buttons: [.approve, .reject, .edit]),
                                             state: .failed(message: "the CLI timed out"), failedVerb: "approve")
        XCTAssertTrue(pending.footerOffersRetry, "a failed Approve is repeated from the footer")
        XCTAssertTrue(InboxRowActionsContent(kind: .reminder, state: .failed(message: "busy")).footerOffersRetry)
    }

    /// Approved, then execution failed: the footer never repeats Approve on a row no longer pending.
    func testFooterRetryNeverApprovesARowThatLeftPending() {
        XCTAssertNil(InboxRowActionsContent.actionRetry(verb: "approve", buttons: [.retry]))
        XCTAssertNil(InboxRowActionsContent.actionRetry(verb: "approve", buttons: [.dismiss]))
        XCTAssertEqual(InboxRowActionsContent.actionRetry(verb: "approve", buttons: [.approve, .reject, .edit]),
                       .approve)
        let dismissRow = InboxRowActionsContent(kind: .action(summary: "claude.ai Gmail", buttons: [.dismiss]),
                                                state: .failed(message: "refused"), failedVerb: "approve")
        XCTAssertFalse(dismissRow.footerOffersRetry)
    }

    func testFooterRetryAfterApproveThenFailedApplyDoesNotApproveAgain() async throws {
        let id = try await pool.write { db in try TestDatabase.insertAgentAction(db, status: "pending") }
        let runner = FakeCLIRunner(error: Failure())
        let vm = await strip(runner)
        let ref = InboxRef(kind: .action, id: id)
        await handler(vm).press(.approve, on: ref)
        XCTAssertEqual(vm.actionFeed.rowErrors[id]?.verb, "approve")
        // The approval landed after all and its execution failed.
        try await pool.write { db in
            try db.execute(sql: "UPDATE agent_actions SET status = 'failed', error = 'archived' WHERE id = ?",
                           arguments: [id])
        }
        await vm.refresh()
        XCTAssertEqual(hooks(vm).content(ref, .inbox)?.footerOffersRetry, false)
        await handler(vm).press(.retryFailedPress, on: ref)
        XCTAssertEqual(runner.invocations.filter { $0.prefix(2) == ["actions", "approve"] }.count, 1,
                       "no second Approve on a failed proposal")
    }

    func testDuplicatesSuppressedPerKind() {
        XCTAssertEqual(InboxRefHooks.nativeKinds(.inboxItem), [.open, .chat, .agent])
        XCTAssertEqual(InboxRefHooks.nativeKinds(.inboxItem, hasReply: true), [.open, .chat, .agent, .reply])
        XCTAssertEqual(InboxRefHooks.nativeKinds(.track), [.target])
        XCTAssertEqual(InboxRefHooks.nativeKinds(.idea), [.target])
        XCTAssertEqual(InboxRefHooks.nativeKinds(.reminder), [.open])
        XCTAssertEqual(InboxRefHooks.nativeKinds(.action), [])
    }

    func testPreviewDrawsDisabled() async throws {
        let id = try insertReminder()
        let vm = await strip()
        XCTAssertEqual(hooks(vm).content(InboxRef(kind: .reminder, id: id), .preview)?.isPreview, true)
        XCTAssertEqual(hooks(vm).content(InboxRef(kind: .reminder, id: id), .inbox)?.isPreview, false)
    }

    func testRefToDeletedRecordIsNotDrawn() async throws {
        let vm = await strip()
        let hooks = hooks(vm).hooks
        XCTAssertFalse(hooks.isOpen(ArtifactRef(kind: .reminder, id: 99)))
        XCTAssertNil(hooks.nativeActions(ArtifactRef(kind: .reminder, id: 99), .inbox))
        XCTAssertNil(hooks.nativeFooter(ArtifactRef(kind: .reminder, id: 99), .inbox))
    }

    func testOnlyAnIdeaRowOpensItsCard() async {
        let vm = await strip()
        let hooks = hooks(vm).hooks
        XCTAssertNotNil(hooks.open(ArtifactRef(kind: .idea, id: 1)))
        for kind in [ArtifactRefKind.inboxItem, .track, .reminder, .action] {
            XCTAssertNil(hooks.open(ArtifactRef(kind: kind, id: 1)), "\(kind)")
        }
    }

    // MARK: - Presses call today's functions

    func testInboxItemPressesRunTheInboxCLI() async throws {
        let id = try await pool.write { db in try TestDatabase.insertInboxItem(db) }
        let runner = FakeCLIRunner()
        let vm = await strip(runner)
        let ref = InboxRef(kind: .inboxItem, id: id)
        await handler(vm).press(.done, on: ref)
        await handler(vm).press(.hide, on: ref)
        await handler(vm).press(.snooze(duration: "3d"), on: ref)
        XCTAssertEqual(runner.invocations, [["inbox", "resolve", "\(id)"], ["inbox", "dismiss", "\(id)"],
                                            ["inbox", "snooze", "\(id)", "3d"]])
    }

    func testDiscussInChatIsTheCardsCommand() async throws {
        let id = try await pool.write { db in try TestDatabase.insertInboxItem(db) }
        let vm = await strip()
        var commands: [InboxCardCommand] = []
        // swiftlint:disable:next trailing_closure
        await handler(vm, onCommand: { commands.append($0) }).press(.discussInChat, on: InboxRef(kind: .inboxItem, id: id))
        let row = try XCTUnwrap(vm.feed.messages.first)
        let subject = InboxCardSubject(message: row)
        XCTAssertEqual(commands, [.chat(subject, message: InboxCardTexts.discussMessage(subject))])
    }

    func testActionPressesGoThroughTheFeed() async throws {
        let id = try await pool.write { db in try TestDatabase.insertAgentAction(db, status: "pending") }
        let runner = FakeCLIRunner(stdout: Self.okEnvelope)
        let vm = await strip(runner)
        let args = try XCTUnwrap(vm.feed.proposals.first?.argsJSON)
        await handler(vm).press(.approve, on: InboxRef(kind: .action, id: id))
        await handler(vm).press(.reject, on: InboxRef(kind: .action, id: id))
        XCTAssertEqual(runner.invocations.map { Array($0.prefix(3)) },
                       [["actions", "approve", "\(id)"], ["actions", "reject", "\(id)"]])
        XCTAssertTrue(runner.invocations[0].contains(AgentActionFeed.argsSHA256(args)))
    }

    func testEditOpensTheNativeEditor() async throws {
        let id = try await pool.write { db in try TestDatabase.insertAgentAction(db, status: "pending") }
        let runner = FakeCLIRunner()
        let vm = await strip(runner)
        var edited: [Int64] = []
        // swiftlint:disable:next trailing_closure
        await handler(vm, onEdit: { edited.append($0) }).press(.edit, on: InboxRef(kind: .action, id: id))
        XCTAssertEqual(edited, [id])
        XCTAssertTrue(runner.invocations.isEmpty)
    }

    func testSuccessRemovesTheRow() async throws {
        let id = try insertReminder()
        let output = try insertApprovalCard(refs: [InboxRef(kind: .reminder, id: id)])
        let vm = await strip()
        let hooks = hooks(vm).hooks
        XCTAssertTrue(hooks.isOpen(ArtifactRef(kind: .reminder, id: id)), "card \(output)")
        await handler(vm).press(.done, on: InboxRef(kind: .reminder, id: id))
        XCTAssertFalse(self.hooks(vm).hooks.isOpen(ArtifactRef(kind: .reminder, id: id)))
        XCTAssertNil(vm.rowErrors[.reminder(id)])
    }

    /// A Needs approval card with one row per ref (the built-in's shape).
    private func insertApprovalCard(refs: [InboxRef]) throws -> Int64 {
        try pool.write { db in
            let automation = try TestDatabase.insertAutomation(db, slug: "needs-approval", name: "Needs approval")
            try db.execute(sql: "UPDATE automations SET origin = 'builtin', builtin_id = ? WHERE id = ?",
                           arguments: [InboxFolderQueries.needsApprovalBuiltinID, automation])
            let run = try TestDatabase.insertAutomationRun(db, automationID: automation)
            let rows = refs.map { #"{"title":"Row","ref":{"kind":"\#($0.kind.rawValue)","id":\#($0.id)}}"# }
            let blocks = #"{"v":1,"blocks":[{"type":"list","rows":[\#(rows.joined(separator: ","))]}]}"#
            return try TestDatabase.insertAutomationOutput(
                db, automationID: automation, runID: run, blocksJSON: blocks,
                outputKey: "\(refs[0].kind.rawValue):\(refs[0].id)", contentHash: "h")
        }
    }

    // MARK: - Busy

    func testBusyDisablesOnlyThatRow() async throws {
        let (first, second) = try await pool.write { db in
            (try TestDatabase.insertInboxItem(db, messageTS: "1700000000.000100"),
             try TestDatabase.insertInboxItem(db, messageTS: "1700000000.000200"))
        }
        let gate = Gate()
        let runner = FakeCLIRunner()
        runner.onRun = { _ in await gate.wait() }
        let vm = await strip(runner)
        let press = Task { await handler(vm).press(.done, on: InboxRef(kind: .inboxItem, id: first)) }
        while !vm.isWriting(.message(Int(first))) { await Task.yield() }
        XCTAssertEqual(hooks(vm).content(InboxRef(kind: .inboxItem, id: first), .inbox)?.state, .busy)
        XCTAssertEqual(hooks(vm).content(InboxRef(kind: .inboxItem, id: second), .inbox)?.state, .idle)
        await gate.open()
        await press.value
    }

    func testActionBusyReadsInFlight() async throws {
        let id = try await pool.write { db in try TestDatabase.insertAgentAction(db, status: "pending") }
        let gate = Gate()
        let runner = FakeCLIRunner(stdout: Self.okEnvelope)
        runner.onRun = { _ in await gate.wait() }
        let vm = await strip(runner)
        let press = Task { await handler(vm).press(.approve, on: InboxRef(kind: .action, id: id)) }
        while !vm.actionFeed.inFlight.contains(id) { await Task.yield() }
        XCTAssertFalse(vm.isWriting(.proposal(id)), "the feed never uses the strip's pending writes")
        XCTAssertEqual(hooks(vm).content(InboxRef(kind: .action, id: id), .inbox)?.state, .busy)
        await gate.open()
        await press.value
    }

    // MARK: - Failure and Retry, per kind

    func testFailedWriteKeepsRowAndRetryRepeatsPress_inboxItem() async throws {
        let id = try await pool.write { db in try TestDatabase.insertInboxItem(db) }
        let runner = FakeCLIRunner(error: Failure())
        let vm = await strip(runner)
        let ref = InboxRef(kind: .inboxItem, id: id)
        await handler(vm).press(.snooze(duration: "1w"), on: ref)
        XCTAssertEqual(hooks(vm).content(ref, .inbox)?.state, .failed(message: "the watchtower CLI timed out"))
        runner.shouldThrow = nil
        await handler(vm).press(.retryFailedPress, on: ref)
        XCTAssertEqual(runner.invocations, Array(repeating: ["inbox", "snooze", "\(id)", "1w"], count: 2))
        XCTAssertNil(vm.rowErrors[.message(Int(id))])
    }

    func testFailedWriteKeepsRowAndRetryRepeatsPress_track() async throws {
        let id = try await pool.write { db in try TestDatabase.insertTrack(db) }
        try failUpdates(on: "tracks")
        let vm = await strip()
        let ref = InboxRef(kind: .track, id: id)
        await handler(vm).press(.done, on: ref)
        XCTAssertEqual(vm.rowErrors[.track(Int(id))]?.press, .done)
        guard case .failed? = hooks(vm).content(ref, .inbox)?.state else {
            return XCTFail("the track row keeps its failure")
        }
        try allowUpdates(on: "tracks")
        await handler(vm).press(.retryFailedPress, on: ref)
        XCTAssertNil(vm.rowErrors[.track(Int(id))])
        let readAt = try await pool.read { db in
            try String.fetchOne(db, sql: "SELECT read_at FROM tracks WHERE id = ?", arguments: [id])
        }
        XCTAssertNotNil(readAt)
    }

    func testFailedWriteKeepsRowAndRetryRepeatsPress_reminder() async throws {
        let id = try insertReminder()
        try failUpdates(on: "reminders")
        let runner = FakeCLIRunner()
        let vm = await strip(runner)
        let ref = InboxRef(kind: .reminder, id: id)
        await handler(vm).press(.snoozeHour, on: ref)
        XCTAssertEqual(vm.rowErrors[.reminder(id)]?.press, .snoozeHour)
        try allowUpdates(on: "reminders")
        await handler(vm).press(.retryFailedPress, on: ref)
        XCTAssertNil(vm.rowErrors[.reminder(id)])
        XCTAssertTrue(vm.reminderRows.isEmpty, "snoozed an hour out of the due window")
    }

    func testFailedWriteKeepsRowAndRetryRepeatsPress_action() async throws {
        let id = try await pool.write { db in try TestDatabase.insertAgentAction(db, status: "pending") }
        let runner = FakeCLIRunner(stdout: Self.okEnvelope, error: Failure())
        let vm = await strip(runner)
        let ref = InboxRef(kind: .action, id: id)
        await handler(vm).press(.reject, on: ref)
        XCTAssertEqual(hooks(vm).content(ref, .inbox)?.state, .failed(message: "the watchtower CLI timed out"))
        runner.shouldThrow = nil
        await handler(vm).press(.retryFailedPress, on: ref)
        XCTAssertEqual(runner.invocations.map { Array($0.prefix(3)) },
                       Array(repeating: ["actions", "reject", "\(id)"], count: 2))
        XCTAssertNil(vm.actionFeed.rowErrors[id])
    }

    func testFailedWriteKeepsRowAndRetryRepeatsPress_idea() async throws {
        let id = try await pool.write { db in try TestDatabase.insertIdea(db, status: "proposed") }
        try failUpdates(on: "ideas")
        let ideas = IdeasViewModel(dbManager: manager)
        let vm = await strip()
        let ref = InboxRef(kind: .idea, id: id)
        await handler(vm, ideas: ideas).press(.approve, on: ref)
        let failure = try XCTUnwrap(vm.rowErrors[.idea(Int(id))])
        XCTAssertEqual(failure.press, .approve)
        XCTAssertEqual(failure.message, ideas.errorMessage)
        try allowUpdates(on: "ideas")
        await handler(vm, ideas: ideas).press(.retryFailedPress, on: ref)
        XCTAssertNil(vm.rowErrors[.idea(Int(id))])
        let status = try await pool.read { db in
            try String.fetchOne(db, sql: "SELECT status FROM ideas WHERE id = ?", arguments: [id])
        }
        XCTAssertEqual(status, "active")
    }

    func testRowErrorSurvivesRefresh() async throws {
        let id = try await pool.write { db in try TestDatabase.insertInboxItem(db) }
        let vm = await strip(FakeCLIRunner(error: Failure()))
        await handler(vm).press(.done, on: InboxRef(kind: .inboxItem, id: id))
        await vm.refresh()
        XCTAssertNil(vm.lastError, "refresh clears the strip-wide line")
        XCTAssertEqual(vm.rowErrors[.message(Int(id))]?.message, "the watchtower CLI timed out")
    }

    func testApproveWithChangedArgsShowsRefusalOnRow() async throws {
        let id = try await pool.write { db in try TestDatabase.insertAgentAction(db, status: "pending") }
        let refusal = Data(#"{"ok":false,"applied_ok":false,"error":"This proposal changed — look again"}"#.utf8)
        let runner = FakeCLIRunner(stdout: refusal)
        let vm = await strip(runner)
        let ref = InboxRef(kind: .action, id: id)
        await handler(vm).press(.approve, on: ref)
        XCTAssertEqual(hooks(vm).content(ref, .inbox)?.state,
                       .failed(message: "This proposal changed — look again"))
        // Retry pins the args the row has now, never the ones first shown.
        try await pool.write { db in
            try db.execute(sql: #"UPDATE agent_actions SET args_json = '{"text":"Call colleague A"}' WHERE id = ?"#,
                           arguments: [id])
        }
        await vm.refresh()
        await handler(vm).press(.retryFailedPress, on: ref)
        XCTAssertTrue(runner.invocations[1].contains(AgentActionFeed.argsSHA256(#"{"text":"Call colleague A"}"#)))
    }

    func testVanishedRecordLeavesQuietly() async throws {
        let id = try insertReminder()
        let vm = await strip()
        try await pool.write { db in try db.execute(sql: "DELETE FROM reminders WHERE id = ?", arguments: [id]) }
        await handler(vm).press(.snoozeHour, on: InboxRef(kind: .reminder, id: id))
        XCTAssertNil(vm.rowErrors[.reminder(id)])
        XCTAssertTrue(vm.reminderRows.isEmpty)
    }

    // MARK: - The reminder's Needs approval fire

    func testReminderFireRunsOnceAfterSuccess() async throws {
        let id = try insertReminder()
        let runner = FakeCLIRunner()
        let vm = await strip(runner)
        await handler(vm).press(.done, on: InboxRef(kind: .reminder, id: id))
        XCTAssertEqual(runner.invocations, [["inbox", "approvals", "changed", "--ref", "reminder:\(id)"]])
    }

    /// The fire runs after the press settles: the CLI process never holds the row busy.
    func testReminderFireDoesNotHoldTheRowBusy() async throws {
        let id = try insertReminder()
        let runner = FakeCLIRunner()
        let vm = await strip(runner)
        let busyDuringFire = LockedFlag()
        runner.onRun = { [weak vm] _ in
            let busy = await MainActor.run { vm?.isWriting(.reminder(id)) ?? true }
            if busy { busyDuringFire.set() }
        }
        await handler(vm).press(.done, on: InboxRef(kind: .reminder, id: id))
        XCTAssertEqual(runner.invocations.count, 1)
        XCTAssertFalse(busyDuringFire.value)
    }

    func testReminderFireNotRunAfterFailure() async throws {
        let id = try insertReminder()
        try failUpdates(on: "reminders")
        let runner = FakeCLIRunner()
        let vm = await strip(runner)
        await handler(vm).press(.done, on: InboxRef(kind: .reminder, id: id))
        XCTAssertTrue(runner.invocations.isEmpty)
    }

    func testReminderFireFailureIgnored() async throws {
        let id = try insertReminder()
        let runner = FakeCLIRunner(error: Failure())
        let vm = await strip(runner)
        await handler(vm).press(.done, on: InboxRef(kind: .reminder, id: id))
        XCTAssertEqual(runner.invocations.count, 1)
        XCTAssertNil(vm.rowErrors[.reminder(id)])
        XCTAssertNil(vm.lastError)
        XCTAssertTrue(vm.reminderRows.isEmpty)
    }
}

/// Holds a fake CLI call until the test opens it.
private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

/// A flag `FakeCLIRunner.onRun` sets off the main actor.
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool { lock.withLock { stored } }
    func set() { lock.withLock { stored = true } }
}
