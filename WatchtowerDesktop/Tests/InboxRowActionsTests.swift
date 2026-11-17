import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerInterface
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

    /// A strip over Go's case `name` (seeded into the pool), following its
    /// steps through the fake tower; `findCLI` as the app finds the binary.
    private func listed(
        _ name: String,
        _ runner: FakeCLIRunner = FakeCLIRunner(),
        findCLI: (@MainActor () -> (any CLIRunnerProtocol)?)? = nil
    ) async throws -> ActionStripViewModel {
        let tower = try FeedCaseTransport.seeded(name, pool: pool)
        let vm = if let findCLI {
            ActionStripViewModel(dbPool: pool, findCLI: findCLI)
        } else {
            ActionStripViewModel(dbPool: pool, cliRunner: runner)
        }
        await vm.follow(tower)
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
        // Item 1, a Slack mention with its permalink: Go's facts say Reply….
        let id: Int64 = 1
        let vm = try await listed("desktop_rows_slack_item")
        let content = try XCTUnwrap(hooks(vm).content(InboxRef(kind: .inboxItem, id: id), .inbox))
        // `InboxMessagePane`: Open in Slack (a permalink), Discuss in Chat,
        // Hand to Agent…, Done, Hide, Snooze ▾; Reply… for a Slack item (Task 18).
        XCTAssertEqual(content.kind, .inboxItem(openLabel: "Open in Slack", openEnabled: true, canReply: true,
                                                showsHandToAgent: true))
        XCTAssertEqual(content.state, .idle)
    }

    func testInboxItemWithoutPermalinkHasNoOpen() async throws {
        // Item 1, a mention with no permalink.
        let id: Int64 = 1
        let vm = try await listed("desktop_rows_item_without_permalink")
        let content = try XCTUnwrap(hooks(vm).content(InboxRef(kind: .inboxItem, id: id), .inbox))
        XCTAssertEqual(content.kind, .inboxItem(openLabel: nil, openEnabled: false, canReply: false,
                                                showsHandToAgent: true))
    }

    func testTrackDrawsTheTrackCardsActions() async throws {
        // Track 1 automatic; track 2 custom, linked to target 4.
        let (auto, custom, target): (Int64, Int64, Int64) = (1, 2, 4)
        let vm = try await listed("desktop_rows_auto_and_custom_track")
        XCTAssertEqual(hooks(vm).content(InboxRef(kind: .track, id: auto), .inbox)?.kind,
                       .track(custom: false, linkedTargetID: nil))
        XCTAssertEqual(hooks(vm).content(InboxRef(kind: .track, id: custom), .inbox)?.kind,
                       .track(custom: true, linkedTargetID: Int64(target)))
    }

    func testIdeaDrawsItsVerdictButtons() async throws {
        // Artifact 1's rows: idea 1 proposed (awaits a verdict), idea 2 active.
        // Whether it awaits a verdict is Go's `waits` of the row.
        let vm = try await listed("desktop_rows_idea_refs")
        for (id, waits) in [(Int64(1), true), (2, false)] {
            let idea = try XCTUnwrap(vm.feed.ideas.first { Int64($0.id) == id })
            let content = try XCTUnwrap(hooks(vm).content(InboxRef(kind: .idea, id: id), .inbox))
            XCTAssertEqual(content.kind, .idea(kind: .idea, status: idea.status, awaitsVerdict: waits))
        }
    }

    func testReminderDrawsDoneAndSnooze() async throws {
        let id: Int64 = 1
        let vm = try await listed("desktop_strip_reminder_done")
        XCTAssertEqual(hooks(vm).content(InboxRef(kind: .reminder, id: id), .inbox)?.kind, .reminder)
    }

    /// The proposals of `desktop_rows_action_kinds`, by id: each a kind of
    /// row the native buttons tell apart.
    private enum Kind: Int64 {
        case pending = 1, failed, jiraIssue, connectorUnreadable, saveAutomation, connector, connectorUnknownOutcome
        case slackPick, slackPinned, confluenceEdit
    }

    /// The strip over `desktop_rows_action_kinds`, listed once per test.
    private var kindsStrip: ActionStripViewModel?

    private func actionKinds() async throws -> ActionStripViewModel {
        if let kindsStrip { return kindsStrip }
        let vm = try await listed("desktop_rows_action_kinds")
        kindsStrip = vm
        return vm
    }

    /// The row's buttons for one proposal row, as the Inbox reads it.
    private func actionButtons(
        _ kind: Kind = .pending,
        sessionHolds: Bool = false
    ) async throws -> [InboxRowActionsContent.ActionButton]? {
        let id = kind.rawValue
        let vm = try await actionKinds()
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
        let failed = try await actionButtons(.failed)
        XCTAssertEqual(failed, [.retry])
    }

    /// A target button's failed row with a newer row of the same button: no
    /// Retry on its recipe row, and a Retry press does nothing — the native
    /// card's `offersRetry` gate (Go refuses it with exit 3).
    func testSupersededButtonRowOffersNoRetry() async throws {
        // Button 5:0's failed row 1 and its newer pending row 2: Go says
        // which row is superseded (`Approval.superseded`).
        let (older, newer): (Int64, Int64) = (1, 2)
        let runner = FakeCLIRunner(stdout: Self.okEnvelope)
        let vm = try await listed("desktop_rows_superseded_button", runner)
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
        let id = Kind.jiraIssue.rawValue
        let vm = try await actionKinds()
        let hooks = hooks(vm)
        let content = try XCTUnwrap(hooks.content(InboxRef(kind: .action, id: id), .inbox))
        let summary = try XCTUnwrap(content.actionSummary)
        XCTAssertTrue(summary.contains("ACME"), summary)
        XCTAssertTrue(summary.contains("Fix the link"), summary)
        let action = try XCTUnwrap(vm.feed.proposals.first { $0.id == id })
        XCTAssertFalse(summary.contains(AgentActionCardView.title(for: action)), summary)
        XCTAssertEqual(content.state, .idle)
        XCTAssertNotNil(hooks.hooks.nativeFooter(ArtifactRef(kind: .action, id: id), .inbox),
                        "an idle proposal row draws its summary under the line")
    }

    /// A proposal with nothing readable in its args keeps the tool's name as its words.
    func testActionRowSummaryFallsBackToTheToolTitle() async throws {
        let id = Kind.connectorUnreadable.rawValue
        let vm = try await actionKinds()
        let action = try XCTUnwrap(vm.feed.proposals.first { $0.id == id })
        XCTAssertEqual(AgentActionCardView.rowSummary(for: action), AgentActionCardView.title(for: action))
    }

    /// A pending `save_automation` is saved in the editor only: Open Draft and Reject, never Approve.
    func testSaveAutomationRowOpensTheDraftNeverApproves() async throws {
        let buttons = try await actionButtons(.saveAutomation)
        XCTAssertEqual(buttons, [.openDraft, .reject])
    }

    /// A session call: Approve only while its chat session holds it; Retry never.
    func testConnectorCallApprovesOnlyWhileTheSessionHoldsIt() async throws {
        let held = try await actionButtons(.connector, sessionHolds: true)
        XCTAssertEqual(held, [.approve, .reject, .edit])
        let gone = try await actionButtons(.connector)
        XCTAssertEqual(gone, [.reject, .edit])
        let unreadable = try await actionButtons(.connectorUnreadable, sessionHolds: true)
        XCTAssertEqual(unreadable, [.reject, .edit])
    }

    func testConnectorCallWithUnknownOutcomeOffersDismissOnly() async throws {
        // Row 7 failed with `ConnectorCallProposal.sessionEndedWhileRunning`.
        let buttons = try await actionButtons(.connectorUnknownOutcome)
        XCTAssertEqual(buttons, [.dismiss])
    }

    /// A Slack send whose workspace is still to be picked approves on its card only.
    func testSlackSendNeedingAPickHasNoRowApprove() async throws {
        let picking = try await actionButtons(.slackPick)
        XCTAssertEqual(picking, [.reject, .edit])
        let ready = try await actionButtons(.slackPinned)
        XCTAssertEqual(ready, [.approve, .reject, .edit])
    }

    /// An edit the card cannot show is never approved (F7).
    func testUnreadableConfluenceEditHasNoApprove() async throws {
        let buttons = try await actionButtons(.confluenceEdit)
        XCTAssertEqual(buttons, [.reject, .edit])
    }

    func testOpenDraftOpensTheSaveProposalsDraft() async throws {
        let id = Kind.saveAutomation.rawValue
        let runner = FakeCLIRunner()
        let vm = try await listed("desktop_rows_action_kinds", runner)
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
        // Message 1: a Slack mention with a permalink.
        let id: Int64 = 1
        let ref = InboxRef(kind: .inboxItem, id: Int64(id))
        // Labeled: the missing CLI reads as such.
        // swiftlint:disable:next trailing_closure
        let vm = try await listed("desktop_rows_slack_item", findCLI: { nil })
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
        let present = ActionStripViewModel(dbPool: pool, cliRunner: FakeCLIRunner())
        await present.follow(try FeedCaseTransport("desktop_rows_slack_item", pool: pool))
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
        // Reminder 1, due; Go's next feed once it is done.
        let id: Int64 = 1
        // Labeled: the missing CLI reads as such.
        // swiftlint:disable:next trailing_closure
        let vm = try await listed("desktop_strip_reminder_done", findCLI: { nil })
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
        // Idea 1, proposed.
        let id: Int64 = 1
        let vm = try await listed("desktop_kinds_track_and_idea")
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
        let id: Int64 = 1 // a pending proposal
        let runner = FakeCLIRunner(error: Failure())
        let vm = try await listed("desktop_strip_action_and_reminder", runner)
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
        XCTAssertEqual(InboxRefHooks.nativeKinds(.planItem), [])
    }

    /// A `plan_item` ref is the phone projection's only: on the Mac it has no
    /// Core twin, so its row stays shown and gets no native actions.
    func testPlanItemRefIsAPlainRowOnTheMac() {
        let ref = ArtifactRef(kind: .planItem, id: 21)
        XCTAssertNil(InboxRefHooks.inboxRef(ref))
        let hooks = InboxRefHooks.make(isShown: { _ in false }, content: { _, _ in nil })
        XCTAssertTrue(hooks.isOpen(ref))
        XCTAssertEqual(hooks.nativeKinds(ref), [])
    }

    func testPreviewDrawsDisabled() async throws {
        let id: Int64 = 1 // a due reminder
        let vm = try await listed("desktop_strip_reminder_done")
        XCTAssertEqual(hooks(vm).content(InboxRef(kind: .reminder, id: id), .preview)?.isPreview, true)
        XCTAssertEqual(hooks(vm).content(InboxRef(kind: .reminder, id: id), .inbox)?.isPreview, false)
    }

    func testRefToDeletedRecordIsNotDrawn() async throws {
        let vm = try await listed("desktop_rows_empty")
        let hooks = hooks(vm).hooks
        XCTAssertFalse(hooks.isOpen(ArtifactRef(kind: .reminder, id: 99)))
        XCTAssertNil(hooks.nativeActions(ArtifactRef(kind: .reminder, id: 99), .inbox))
        XCTAssertNil(hooks.nativeFooter(ArtifactRef(kind: .reminder, id: 99), .inbox))
    }

    func testOnlyAnIdeaRowOpensItsCard() async throws {
        let vm = try await listed("desktop_rows_empty")
        let hooks = hooks(vm).hooks
        XCTAssertNotNil(hooks.open(ArtifactRef(kind: .idea, id: 1)))
        for kind in [ArtifactRefKind.inboxItem, .track, .reminder, .action] {
            XCTAssertNil(hooks.open(ArtifactRef(kind: kind, id: 1)), "\(kind)")
        }
    }

    // MARK: - Presses call today's functions

    func testInboxItemPressesRunTheInboxCLI() async throws {
        let id: Int64 = 1 // a pending Slack mention
        let runner = FakeCLIRunner()
        let vm = try await listed("desktop_rows_slack_item", runner)
        let ref = InboxRef(kind: .inboxItem, id: id)
        await handler(vm).press(.done, on: ref)
        await handler(vm).press(.hide, on: ref)
        await handler(vm).press(.snooze(duration: "3d"), on: ref)
        XCTAssertEqual(runner.invocations, [["inbox", "resolve", "\(id)"], ["inbox", "dismiss", "\(id)"],
                                            ["inbox", "snooze", "\(id)", "3d"]])
    }

    func testDiscussInChatIsTheCardsCommand() async throws {
        let id: Int64 = 1 // a pending Slack mention
        let vm = try await listed("desktop_rows_slack_item")
        var commands: [InboxCardCommand] = []
        // swiftlint:disable:next trailing_closure
        await handler(vm, onCommand: { commands.append($0) }).press(.discussInChat, on: InboxRef(kind: .inboxItem, id: id))
        let row = try XCTUnwrap(vm.feed.messages.first)
        let subject = InboxCardSubject(message: row)
        XCTAssertEqual(commands, [.chat(subject, message: InboxCardTexts.discussMessage(subject))])
    }

    func testActionPressesGoThroughTheFeed() async throws {
        let id: Int64 = 1 // a pending proposal
        let runner = FakeCLIRunner(stdout: Self.okEnvelope)
        let vm = try await listed("desktop_strip_action_and_reminder", runner)
        let args = try XCTUnwrap(vm.feed.proposals.first?.argsJSON)
        await handler(vm).press(.approve, on: InboxRef(kind: .action, id: id))
        await handler(vm).press(.reject, on: InboxRef(kind: .action, id: id))
        XCTAssertEqual(runner.invocations.map { Array($0.prefix(3)) },
                       [["actions", "approve", "\(id)"], ["actions", "reject", "\(id)"]])
        XCTAssertTrue(runner.invocations[0].contains(AgentActionFeed.argsSHA256(args)))
    }

    func testEditOpensTheNativeEditor() async throws {
        let id: Int64 = 1 // a pending proposal
        let runner = FakeCLIRunner()
        let vm = try await listed("desktop_strip_action_and_reminder", runner)
        var edited: [Int64] = []
        // swiftlint:disable:next trailing_closure
        await handler(vm, onEdit: { edited.append($0) }).press(.edit, on: InboxRef(kind: .action, id: id))
        XCTAssertEqual(edited, [id])
        XCTAssertTrue(runner.invocations.isEmpty)
    }

    func testSuccessRemovesTheRow() async throws {
        // Reminder 1, due, and Needs approval's card 1 with its row; Go's next feed once it is done.
        let (id, output): (Int64, Int64) = (1, 1)
        let vm = try await listed("desktop_rows_reminder_on_approval_card")
        let hooks = hooks(vm).hooks
        XCTAssertTrue(hooks.isOpen(ArtifactRef(kind: .reminder, id: id)), "card \(output)")
        await handler(vm).press(.done, on: InboxRef(kind: .reminder, id: id))
        XCTAssertFalse(self.hooks(vm).hooks.isOpen(ArtifactRef(kind: .reminder, id: id)))
        XCTAssertNil(vm.rowErrors[.reminder(id)])
    }

    // MARK: - Busy

    func testBusyDisablesOnlyThatRow() async throws {
        // Items 1 and 2, both listed under Messages.
        let (first, second): (Int64, Int64) = (1, 2)
        let gate = Gate()
        let runner = FakeCLIRunner()
        runner.onRun = { _ in await gate.wait() }
        let vm = try await listed("desktop_reply_slack_and_mail", runner)
        let press = Task { await handler(vm).press(.done, on: InboxRef(kind: .inboxItem, id: first)) }
        // Bounded: a press that never starts fails, never hangs.
        for _ in 0..<100_000 where !vm.isWriting(.message(Int(first))) { await Task.yield() }
        guard vm.isWriting(.message(Int(first))) else {
            await gate.open()
            return XCTFail("the Done press never started")
        }
        XCTAssertEqual(hooks(vm).content(InboxRef(kind: .inboxItem, id: first), .inbox)?.state, .busy)
        XCTAssertEqual(hooks(vm).content(InboxRef(kind: .inboxItem, id: second), .inbox)?.state, .idle)
        await gate.open()
        await press.value
    }

    func testActionBusyReadsInFlight() async throws {
        let id: Int64 = 1 // a pending proposal
        let gate = Gate()
        let runner = FakeCLIRunner(stdout: Self.okEnvelope)
        runner.onRun = { _ in await gate.wait() }
        let vm = try await listed("desktop_strip_action_and_reminder", runner)
        let press = Task { await handler(vm).press(.approve, on: InboxRef(kind: .action, id: id)) }
        // Bounded: a press that never reaches the feed fails, never hangs.
        for _ in 0..<100_000 where !vm.actionFeed.inFlight.contains(id) { await Task.yield() }
        guard vm.actionFeed.inFlight.contains(id) else {
            await gate.open()
            return XCTFail("the approve never reached the feed")
        }
        XCTAssertFalse(vm.isWriting(.proposal(id)), "the feed never uses the strip's pending writes")
        XCTAssertEqual(hooks(vm).content(InboxRef(kind: .action, id: id), .inbox)?.state, .busy)
        await gate.open()
        await press.value
    }

    // MARK: - Failure and Retry, per kind

    func testFailedWriteKeepsRowAndRetryRepeatsPress_inboxItem() async throws {
        let id: Int64 = 1 // a pending Slack mention
        let runner = FakeCLIRunner(error: Failure())
        let vm = try await listed("desktop_rows_slack_item", runner)
        let ref = InboxRef(kind: .inboxItem, id: id)
        await handler(vm).press(.snooze(duration: "1w"), on: ref)
        XCTAssertEqual(hooks(vm).content(ref, .inbox)?.state, .failed(message: "the watchtower CLI timed out"))
        runner.shouldThrow = nil
        await handler(vm).press(.retryFailedPress, on: ref)
        XCTAssertEqual(runner.invocations, Array(repeating: ["inbox", "snooze", "\(id)", "1w"], count: 2))
        XCTAssertNil(vm.rowErrors[.message(Int(id))])
    }

    func testFailedWriteKeepsRowAndRetryRepeatsPress_track() async throws {
        let id: Int64 = 1 // an automatic track
        let vm = try await listed("desktop_kinds_track_and_idea")
        try failUpdates(on: "tracks")
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
        // Reminder 1, due; Go's next feed once it is snoozed out of the due window.
        let id: Int64 = 1
        let vm = try await listed("desktop_rows_reminder_snoozed_an_hour")
        try failUpdates(on: "reminders")
        let ref = InboxRef(kind: .reminder, id: id)
        await handler(vm).press(.snoozeHour, on: ref)
        XCTAssertEqual(vm.rowErrors[.reminder(id)]?.press, .snoozeHour)
        try allowUpdates(on: "reminders")
        await handler(vm).press(.retryFailedPress, on: ref)
        XCTAssertNil(vm.rowErrors[.reminder(id)])
        XCTAssertTrue(vm.reminderRows.isEmpty, "snoozed an hour out of the due window")
    }

    func testFailedWriteKeepsRowAndRetryRepeatsPress_action() async throws {
        let id: Int64 = 1 // a pending proposal
        let runner = FakeCLIRunner(stdout: Self.okEnvelope, error: Failure())
        let vm = try await listed("desktop_strip_action_and_reminder", runner)
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
        let id: Int64 = 1 // a proposed idea
        let vm = try await listed("desktop_kinds_track_and_idea")
        try failUpdates(on: "ideas")
        let ideas = IdeasViewModel(dbManager: manager)
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
        let id: Int64 = 1 // a pending Slack mention
        let vm = try await listed("desktop_rows_slack_item", FakeCLIRunner(error: Failure()))
        await handler(vm).press(.done, on: InboxRef(kind: .inboxItem, id: id))
        await vm.refresh()
        XCTAssertNil(vm.lastError, "refresh clears the strip-wide line")
        XCTAssertEqual(vm.rowErrors[.message(Int(id))]?.message, "the watchtower CLI timed out")
    }

    func testApproveWithChangedArgsShowsRefusalOnRow() async throws {
        let id: Int64 = 1 // a pending proposal
        let refusal = Data(#"{"ok":false,"applied_ok":false,"error":"This proposal changed — look again"}"#.utf8)
        let runner = FakeCLIRunner(stdout: refusal)
        let vm = try await listed("desktop_strip_action_and_reminder", runner)
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
        let id: Int64 = 1 // a due reminder
        let vm = try await listed("desktop_strip_reminder_done")
        try await pool.write { db in try db.execute(sql: "DELETE FROM reminders WHERE id = ?", arguments: [id]) }
        await handler(vm).press(.snoozeHour, on: InboxRef(kind: .reminder, id: id))
        XCTAssertNil(vm.rowErrors[.reminder(id)])
        XCTAssertTrue(vm.reminderRows.isEmpty)
    }

    // MARK: - The reminder's Needs approval fire

    func testReminderFireRunsOnceAfterSuccess() async throws {
        let id: Int64 = 1 // a due reminder
        let runner = FakeCLIRunner()
        let vm = try await listed("desktop_strip_reminder_done", runner)
        await handler(vm).press(.done, on: InboxRef(kind: .reminder, id: id))
        XCTAssertEqual(runner.invocations, [["inbox", "approvals", "changed", "--ref", "reminder:\(id)"]])
    }

    /// The fire runs after the press settles: the CLI process never holds the row busy.
    func testReminderFireDoesNotHoldTheRowBusy() async throws {
        let id: Int64 = 1 // a due reminder
        let runner = FakeCLIRunner()
        let vm = try await listed("desktop_strip_reminder_done", runner)
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
        let id: Int64 = 1 // a due reminder
        let runner = FakeCLIRunner()
        let vm = try await listed("desktop_strip_reminder_done", runner)
        try failUpdates(on: "reminders")
        await handler(vm).press(.done, on: InboxRef(kind: .reminder, id: id))
        XCTAssertTrue(runner.invocations.isEmpty)
    }

    func testReminderFireFailureIgnored() async throws {
        // Reminder 1, due; Go's next feed once it is done.
        let id: Int64 = 1
        let runner = FakeCLIRunner(error: Failure())
        let vm = try await listed("desktop_strip_reminder_done", runner)
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
