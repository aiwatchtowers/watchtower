import XCTest
import GRDB
import SwiftUI
import ViewInspector
@testable import WatchtowerDesktop
@testable import WatchtowerCore
import WatchtowerTestSupport

/// The pane with the day, track and idea placeholders (before Tasks 8–10).
private typealias PlaceholderPane = InboxReadingPane<
    InboxCardPlaceholder, InboxCardColumn<InboxCardPlaceholder>, InboxCardPlaceholder>

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
        recipeState: AutomationHeaderButton.State = .runnable,
        recipeRemoved: Bool = false
    ) -> AutomationOutputCard {
        AutomationOutputCard(
            id: 5, automationID: 2, automationName: "Issue triage", runID: 212,
            title: "ACME-482: crash when importing CSV", body: "**Verdict:** bug, high priority.",
            priority: "high", createdAt: Date(timeIntervalSinceReferenceDate: 800_000_000),
            link: link, actionsJSON: actions, pressedAction: pressedAction, pressedRunID: pressedRunID,
            recipeState: recipeState, recipeRemoved: recipeRemoved
        )
    }

    private let twoActions = #"[{"label":"Move to Backlog","kind":"reply","reply":"backlog","primary":true},"#
        + #"{"label":"Draft a Reply","kind":"chat","chat":"Draft a reply"}]"#

    private func pane(
        _ card: AutomationOutputCard,
        navScreens: Set<String> = [],
        onCommand: @escaping (InboxCardCommand) -> Void = { _ in }
    ) -> PlaceholderPane {
        InboxReadingPane(item: .output(card), navScreens: navScreens, onCommand: onCommand)
    }

    private func buttonLabels(_ view: PlaceholderPane) throws -> [String] {
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
            .chat(InboxCardSubject(shown), message: InboxCardTexts.discussMessage(shown)),
            .agent(InboxCardSubject(shown), task: InboxCardTexts.handToAgentTask(shown), workbench: nil)
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

        XCTAssertEqual(commands, [.agent(InboxCardSubject(shown), task: InboxCardTexts.agentActionTask(shown, task: "Fix it"),
                                         workbench: .id(3)),
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

        // A removed recipe: nothing to confirm or turn on, so no press.
        let removed = pane(card(actions: reply, recipeState: .disabled, recipeRemoved: true))
        XCTAssertNoThrow(try removed.inspect().find(text: "Recipe removed"))
        XCTAssertThrowsError(try removed.inspect().find(text: "Off"))
        XCTAssertTrue(try removed.inspect().find(button: "Move to Backlog").isDisabled())
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

    // MARK: - Every kind

    /// 09:30 today, local time, and "now" an hour later the same day.
    private func local(_ hour: Int, _ minute: Int) throws -> Date {
        try XCTUnwrap(Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()))
    }

    private func dayCard() throws -> InboxDayCard {
        let briefing = try Briefing(row: Row([
            "id": 1, "user_id": "u", "date": "2025-10-22", "role": "", "attention": "[]", "your_day": "[]",
            "what_happened": "[]", "team_pulse": "[]", "coaching": "[]", "model": "", "input_tokens": 0,
            "output_tokens": 0, "cost_usd": 0.0, "prompt_version": 1, "read_at": nil,
            "created_at": "2025-10-22T05:00:00Z"
        ] as [String: (any DatabaseValueConvertible)?]))
        return InboxDayCard(date: "2025-10-22", briefing: briefing, plan: nil, planDone: 0, planTotal: 0,
                            stamp: try local(7, 0))
    }

    private func trackCard() throws -> InboxTrackCard {
        let track = Track(row: Row(["id": 3, "text": "Launch of acme v2", "read_at": nil, "has_updates": true,
                                    "priority": "high"] as [String: (any DatabaseValueConvertible)?]))
        return InboxTrackCard(track: track, lastEventAt: try local(9, 30), newEventCount: 2)
    }

    private func idea() -> Idea {
        Idea(row: Row(["id": 4, "kind": "idea", "status": "proposed", "title": "A shared glossary",
                       "essence": "One page of terms", "updated_at": "2026-10-20T10:00:00Z"]))
    }

    private func message() throws -> HomeFeedInboxRow {
        let item = InboxItem(row: Row(["id": 9, "snippet": "Can you review the launch plan?",
                                       "trigger_type": "mention", "permalink": "https://example.com/m/9",
                                       "read_at": ""]))
        return HomeFeedInboxRow(item: item, stamp: try local(9, 12), who: "Ann", whereText: "#eng")
    }

    private func reminder() -> Reminder {
        Reminder(row: Row(["id": 1, "message_ref": "", "note": "Ping Ann", "remind_at": "2000-01-01T00:00:00Z",
                           "status": "pending"]))
    }

    private func proposal() -> AgentAction {
        AgentAction(row: Row(["id": 7, "tool": "create_target", "status": "pending", "reason": "From a reaction"]))
    }

    /// Each kind with the title and source line its pane must show.
    private func everyKind() throws -> [(item: InboxListItem, texts: [String])] {
        let output = card()
        return [
            (.output(output), [output.title]),
            (.reminder(reminder()), ["Ping Ann"]),
            (.proposal(proposal()), [AgentActionCardView.title(for: proposal())]),
            (.day(try dayCard()), ["Morning brief", "Your day · Wed 22 Oct"]),
            (.track(try trackCard()), ["Launch of acme v2", "Track · 09:30"]),
            (.idea(idea()), ["A shared glossary", "Idea · proposed"]),
            (.message(try message()), ["Can you review the launch plan?", "Ann · #eng · 09:12"])
        ]
    }

    func testEveryKindHasAPane() throws {
        let kinds = try everyKind()
        XCTAssertEqual(kinds.count, 7, "every InboxListItem case")
        for (item, texts) in kinds {
            let sut = InboxReadingPane(
                item: item, navScreens: [], now: try local(10, 30), onCommand: { _ in },
                proposalCard: { action in
                    AgentActionCardView(action: action, inFlight: false, onApprove: {}, onReject: {}, onRetry: {})
                })
            XCTAssertThrowsError(try sut.inspect().find(text: "Select a card"), "\(item.id)")
            for text in texts {
                XCTAssertNoThrow(try sut.inspect().find(text: text), "\(item.id): \(text)")
            }
        }
    }

    func testSelectingADayCardShowsTheDayPane() async throws {
        let date = "2025-10-22"
        let pool = try TestDatabase.create()
        try await pool.write { db in
            let planID = try TestDatabase.insertDayPlan(db, planDate: date)
            try TestDatabase.insertDayPlanItem(db, dayPlanID: planID, kind: "backlog", sourceType: "manual",
                                               title: "Write tests")
            try TestDatabase.insertBriefing(
                db, date: date,
                attention: #"[{"text":"Reply to the release thread","priority":"high","source_type":"track","source_id":"3"}]"#)
        }
        let (briefing, dayPlan) = try await pool.read { db in
            (try BriefingQueries.fetchByDate(db, date: date), try DayPlanQueries.fetchByDate(db, date: date))
        }
        let plan = DayPlanViewModel(databasePool: pool, cliRunner: FakeCLIRunner())
        await plan.loadFor(date: date)
        let card = InboxDayCard(date: date, briefing: briefing, plan: dayPlan, planDone: 0,
                                planTotal: plan.items.count, stamp: Date())
        let owner = Owner(id: "1:U1", source: .slack, slackUserID: "1:U1", email: "", jiraAccountID: "",
                          displayName: "Me")
        let sut = InboxReadingPane(
            item: .day(card), navScreens: [], onCommand: { _ in },
            dayCard: { card in
                InboxDayPane(card: card, today: date, plan: plan, owner: owner, onDone: {},
                             onCommand: { _ in }, onOpenSource: { _ in })
            },
            trackCard: { InboxCardPlaceholder(track: $0, now: Date()) },
            ideaCard: { InboxCardPlaceholder(idea: $0) })

        XCTAssertNoThrow(try sut.inspect().find(InboxDayPane.self))
        let texts = try sut.inspect().findAll(ViewType.Text.self).compactMap { try? $0.string() }
        let item = try XCTUnwrap(texts.firstIndex(of: "Write tests"))
        let needsYou = try XCTUnwrap(texts.firstIndex(of: "Needs you"))
        XCTAssertLessThan(item, needsYou, "the plan block comes before Needs you")
    }

    func testListRowContentForEveryKind() throws {
        let now = try local(10, 30)
        func content(_ item: InboxListItem) -> InboxListRow.Content {
            InboxListRow.content(item, proposalLabel: nil, now: now)
        }
        XCTAssertEqual(content(.day(try dayCard())),
                       .init(unread: true, title: "Morning brief", high: false, source: "Your day · Wed 22 Oct",
                             preview: ""))
        XCTAssertEqual(content(.track(try trackCard())),
                       .init(unread: true, title: "Launch of acme v2", high: true, source: "Track · 09:30",
                             preview: "2 new"))
        XCTAssertEqual(content(.idea(idea())),
                       .init(unread: true, title: "A shared glossary", high: false, source: "Idea · proposed",
                             preview: "One page of terms"))
        XCTAssertEqual(content(.message(try message())),
                       .init(unread: true, title: "Can you review the launch plan?", high: false,
                             source: "Ann · #eng · 09:12", preview: ""))

        let readIdea = Idea(row: Row(["id": 5, "kind": "decision", "status": "not_now", "title": "Ship weekly"]))
        XCTAssertEqual(content(.idea(readIdea)).source, "Decision · not now")
        XCTAssertFalse(content(.idea(readIdea)).unread)
    }

    // MARK: - The header

    func testHeaderMoreMenuOffersLearnedRulesAndProfile() throws {
        var opened: [InboxAuxPane] = []
        let sut = InboxFilterBar(filter: .constant(.all), showsCheatSheetButton: true,
                                 onOpenAux: { opened.append($0) }) // swiftlint:disable:this trailing_closure

        try sut.inspect().find(button: "Learned Rules").tap()
        try sut.inspect().find(button: "Assistant Profile").tap()

        XCTAssertEqual(opened, [.learnedRules, .profile])
        for filter in InboxFilter.allCases {
            XCTAssertNoThrow(try sut.inspect().find(text: filter.title), filter.title)
        }
    }

    /// The `?` opens the cheat sheet in the reading pane; the header has no pop-up.
    func testCheatSheetButtonOpensTheReadingPane() throws {
        var opened: [InboxAuxPane] = []
        let sut = InboxFilterBar(filter: .constant(.messages), showsCheatSheetButton: true,
                                 onOpenAux: { opened.append($0) }) // swiftlint:disable:this trailing_closure

        try sut.inspect().find(viewWithAccessibilityIdentifier: "actionStrip.cheatSheetButton").button().tap()

        XCTAssertEqual(opened, [.reactionCommands])
        XCTAssertThrowsError(try sut.inspect().find(ViewType.Popover.self))
    }

    // MARK: - The header's panes in the reading pane

    func testAuxPanesRenderInTheReadingPane() throws {
        let cheatSheet = InboxAuxPaneView(pane: .reactionCommands, cheatSheet: ReactionCheatSheetView(rows: []),
                                          learnedRulesDB: nil, profile: nil) {}
        XCTAssertNoThrow(try cheatSheet.inspect().find(text: "Reaction Commands"))
        XCTAssertNoThrow(try cheatSheet.inspect().find(ReactionCheatSheetView.self))

        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        var closed = 0
        let rules = InboxAuxPaneView(pane: .learnedRules, cheatSheet: nil, learnedRulesDB: pool, profile: nil) {
            closed += 1
        }
        XCTAssertNoThrow(try rules.inspect().find(InboxLearnedRulesView.self))
        try rules.inspect().find(button: "Close").tap()
        XCTAssertEqual(closed, 1)

        let profile = InboxAuxPaneView(pane: .profile, cheatSheet: nil, learnedRulesDB: nil, profile: nil) {}
        XCTAssertNoThrow(try profile.inspect().find(text: "Assistant Profile"))
        XCTAssertNoThrow(try profile.inspect().find(text: "Database unavailable"))
    }

    func testSplitViewShowsTheOpenedPaneInsteadOfTheCard() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let vm = ActionStripViewModel(dbPool: pool, cliRunner: FakeCLIRunner())
        let sut = InboxSplitView(
            vm: vm, proposalCard: Self.proposalCard,
            onCardAction: { _ in }, aux: .constant(.reactionCommands), cheatSheet: ReactionCheatSheetView(rows: []),
            emptyList: { Text("Nothing here") }) // swiftlint:disable:this trailing_closure

        XCTAssertNoThrow(try sut.inspect().find(ReactionCheatSheetView.self))
        XCTAssertThrowsError(try sut.inspect().find(text: "Select a card"))
        XCTAssertNoThrow(try sut.inspect().find(text: "Nothing here"), "the empty list stays on the left")
    }

    /// The Day filter ends with Show older while older dates exist; each
    /// press reads 30 more, and the row goes once nothing older is left.
    func testDayFilterShowOlderReadsAnotherPage() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let suite = "InboxReadingPaneTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try await pool.write { db in
            for day in 1...31 {
                try TestDatabase.insertBriefing(db, date: String(format: "2026-08-%02d", day))
            }
        }
        let vm = ActionStripViewModel(dbPool: pool, cliRunner: FakeCLIRunner(), defaults: defaults)
        vm.filter = .day
        await vm.refresh()
        func split() -> some View {
            InboxSplitView(vm: vm, proposalCard: Self.proposalCard, onCardAction: { _ in },
                           emptyList: { Text("Nothing here") })
        }

        try split().inspect().find(button: "Show older").tap()
        await vm.refresh()

        XCTAssertEqual(vm.dayLimit, 60)
        XCTAssertEqual(vm.feed.days.count, 31)
        XCTAssertThrowsError(try split().inspect().find(button: "Show older"), "nothing older left")
    }

    /// Learned Rules adds a rule inline under its `+`, never in a sheet.
    func testLearnedRulesAddsInline() throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let sut = InboxLearnedRulesView(db: pool)
        XCTAssertNoThrow(try sut.inspect().find(button: "Add Rule"))
        XCTAssertThrowsError(try sut.inspect().find(AddRuleSheet.self), "the form opens on +")
        XCTAssertThrowsError(try sut.inspect().vStack().sheet())
    }

    private static func proposalCard(_ action: AgentAction) -> AgentActionCardView {
        AgentActionCardView(action: action, inFlight: false, onApprove: {}, onReject: {}, onRetry: {})
    }

    // MARK: - Chat attachments

    /// An automation card keeps B's attachment; other kinds carry their subject's.
    func testChatAttachmentKeepsTheAutomationCardsFile() throws {
        let output = card()
        let automation = AppState.inboxChatAttachment(InboxCardSubject(output), outputs: [output])
        XCTAssertEqual(automation.name, "inbox-card-5.md")
        XCTAssertEqual(automation.markdown, """
            # ACME-482: crash when importing CSV

            ϟ Issue triage · run #212

            **Verdict:** bug, high priority.
            """)

        let message = InboxCardSubject(message: try message())
        let other = AppState.inboxChatAttachment(message, outputs: [output])
        XCTAssertEqual(other.name, "inbox-card-message-9.md")
        XCTAssertEqual(other.markdown, InboxCardTexts.attachmentMarkdown(message))

        XCTAssertEqual(AppState.inboxTargetFallbackTitle(InboxCardSubject(output)), "Inbox card #5")
        XCTAssertEqual(AppState.inboxTargetFallbackTitle(message), "Inbox card")
    }

    func testIdeasHeaderShowsOnlyOnTheIdeasFilter() throws {
        let ideas = InboxFilterBar(filter: .constant(.ideas), showsCheatSheetButton: false,
                                   onOpenAux: { _ in }, ideasHeader: { Text("New idea slot") })
        XCTAssertNoThrow(try ideas.inspect().find(text: "New idea slot"))
        XCTAssertThrowsError(try ideas.inspect().find(viewWithAccessibilityIdentifier: "actionStrip.cheatSheetButton"))

        let all = InboxFilterBar(filter: .constant(.all), showsCheatSheetButton: true,
                                 onOpenAux: { _ in }, ideasHeader: { Text("New idea slot") })
        XCTAssertThrowsError(try all.inspect().find(text: "New idea slot"))
    }
}

/// A due reminder in the reading pane links the Slack message it was set
/// from — never the raw `<channel_id>@<message_ts>` ref, and nothing at all
/// without one.
@MainActor
final class InboxReminderPaneTests: XCTestCase {
    private func reminderPane(messageRef: String) -> PlaceholderPane {
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
            .agent(InboxCardSubject(own), task: InboxCardTexts.handToAgentTask(own), workbench: .id(3)),
            .agent(InboxCardSubject(own), task: InboxCardTexts.agentActionTask(own, task: "Fix"), workbench: .id(4))
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
