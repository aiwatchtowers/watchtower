import GRDB
import SwiftUI
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The one Inbox (C1): every kind of card under the filter bar — today's
/// day card, a custom track and an extracted one, ideas and a decision, a
/// message and an automation card — over one fixed moment (2026-10-21
/// 12:00 UTC) handed to the view model's clock and the list, so Today,
/// Earlier and the day labels never move with the real date.
@MainActor
enum OneInboxShotFixtures {
    private static var manager: DatabaseManager?
    private static var path: String?

    static func cleanUp() {
        manager = nil
        if let path { TestDatabase.cleanup(path: path) }
        path = nil
        UserDefaults().removePersistentDomain(forName: defaultsSuite)
    }

    private static let defaultsSuite = "OneInboxShotFixtures"
    nonisolated static let now = AutomationDates.parse("2026-10-21T12:00:00Z") ?? Date()
    private static var today: String { HomeFeedBuilder.dayString(now, calendar: .current) }
    private static let yesterday = "2026-10-20"
    private static let owner = Owner(
        id: "1:U001", source: .slack, slackUserID: "1:U001", email: "", jiraAccountID: "", displayName: "Me"
    )

    /// What a shot opens, and which rows its database holds.
    struct Scene {
        var filter: InboxFilter = .all
        var select: (Seeded) -> InboxSelection? = { _ in nil }
        var withToday = true
        var showsStopped = false
        var dayRow: InboxDayPlanRow?
        var ideasRow: InboxIdeasRow?
        var aux: InboxAuxPane?
    }

    /// The ids the seed wrote.
    struct Seeded {
        let customTrack: Int
        let launchTrack: Int
        let stoppedTrack: Int
        let proposedIdea: Int
        let decision: Int
        let message: Int
    }

    // MARK: - Shots

    static func all() -> AnyView { inbox(Scene { _ in .day(today) }) }
    static func filterDay() -> AnyView { inbox(Scene(filter: .day) { _ in .day(yesterday) }) }
    static func dayCard() -> AnyView { inbox(Scene(filter: .day) { _ in .day(today) }) }
    static func dayCardRegenerate() -> AnyView {
        inbox(Scene(filter: .day, select: { _ in .day(today) }, dayRow: .regenerate))
    }
    static func dayCardEmpty() -> AnyView {
        inbox(Scene(filter: .day, select: { _ in .day(today) }, withToday: false))
    }
    static func trackCard() -> AnyView { inbox(Scene(filter: .tracks) { .track($0.customTrack) }) }
    static func tracksStopped() -> AnyView {
        inbox(Scene(filter: .tracks, select: { .track($0.stoppedTrack) }, showsStopped: true))
    }
    static func ideaCard() -> AnyView { inbox(Scene(filter: .ideas) { .idea($0.proposedIdea) }) }
    static func decisionCard() -> AnyView { inbox(Scene(filter: .ideas) { .idea($0.decision) }) }
    static func ideasNew() -> AnyView {
        inbox(Scene(filter: .ideas, select: { .idea($0.proposedIdea) }, ideasRow: .newIdea))
    }
    static func messageCard() -> AnyView { inbox(Scene(filter: .messages) { .message($0.message) }) }
    static func cheatSheet() -> AnyView { inbox(Scene(aux: .reactionCommands)) }

    /// Today's day card alone at the reading pane's narrowest (420 pt).
    static func dayCardNarrow() -> AnyView {
        do {
            let manager = try freshDatabase()
            _ = try manager.dbPool.write { db in try seed(db, withToday: true) }
            let card = try XCTUnwrap(manager.dbPool.read { db in
                try BriefingQueries.fetchDayCards(db, limit: 1).first
            })
            let plan = DayPlanViewModel(databasePool: manager.dbPool, cliRunner: FakeCLIRunner())
            // In the reading pane's column, which scrolls and pads the card.
            return AnyView(InboxCardColumn { dayPane(card, manager: manager, plan: plan, row: nil) }
                .frame(width: 420)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .environment(AppState())
                .detailBackground())
        } catch {
            return failure(error)
        }
    }

    // MARK: - The Inbox

    private static func inbox(_ scene: Scene) -> AnyView {
        do {
            let manager = try freshDatabase()
            let seeded = try manager.dbPool.write { db in try seed(db, withToday: scene.withToday) }
            let defaults = UserDefaults(suiteName: defaultsSuite) ?? .standard
            defaults.removePersistentDomain(forName: defaultsSuite)
            let clock = now
            let controls = RecordingCustomTrackControls()
            // Labeled: a trailing closure would bind to `automationsWake`.
            // swiftlint:disable trailing_closure
            let vm = ActionStripViewModel(dbPool: manager.dbPool, cliRunner: FakeCLIRunner(),
                                          customTrackControls: controls, defaults: defaults, clock: { clock })
            // swiftlint:enable trailing_closure
            vm.filter = scene.filter
            vm.showsStopped = scene.showsStopped
            refreshed(vm)
            vm.selection = scene.select(seeded)
            let plan = DayPlanViewModel(databasePool: manager.dbPool, cliRunner: FakeCLIRunner())
            let ideas = IdeasViewModel(dbManager: manager, cliRunner: FakeCLIRunner())
            let appState = AppState()
            appState.databaseManager = manager
            appState.embeddedChats.dbPool = manager.dbPool
            appState.trackActionRunnerOverride = FakeCLIRunner()
            return AnyView(ActionStripActionsView(
                vm: vm, cheatSheetRows: cheatSheetRows, feature: .on(lastCheck: nil),
                isEnabling: false, featureError: nil, onEnable: {}, onOpenSettings: {}, onOpen: { _ in },
                dayPane: { card in dayPane(card, manager: manager, plan: plan, row: scene.dayRow) },
                ideas: ideas,
                ideaPane: { idea in InboxIdeaPane(idea: idea, ideas: ideas, allIdeas: vm.feed.ideas) },
                tracks: TracksViewModel(dbManager: manager),
                trackControls: RecordingCustomTrackControls(),
                now: now,
                aux: scene.aux,
                ideasRow: scene.ideasRow
            )
            .environment(appState)
            .environment(\.markdownNavScreens, ["home"])
            .detailBackground())
        } catch {
            return failure(error)
        }
    }

    private static func dayPane(
        _ card: InboxDayCard, manager: DatabaseManager, plan: DayPlanViewModel, row: InboxDayPlanRow?
    ) -> InboxDayPane {
        var pane = InboxDayPane(card: card, today: today, plan: plan, owner: owner,
                                onDone: {}, onCommand: { _ in }, onOpenSource: { _ in })
        pane.briefing = BriefingViewModel(dbManager: manager, cliRunner: FakeCLIRunner())
        pane.emptyState = EmptyStateContext(readiness: { _ in .ready }, briefingHour: 8, dayPlanHour: 9)
        pane.initialRow = row
        return pane
    }

    private static var cheatSheetRows: [ReactionCheatSheet.Row] {
        let mappings = [("white_check_mark", "create_target"), ("eyes", "create_track"), ("bulb", "create_idea"),
                        ("alarm_clock", "remind_me")]
            .map { ReactionCommandMapping(row: ["emoji": $0.0, "tool": $0.1, "enabled": true]) }
        return ReactionCheatSheet.rows(mappings: mappings, trustByTool: ["remind_me": "execute"])
    }

    // MARK: - The database

    private static func freshDatabase() throws -> DatabaseManager {
        cleanUp()
        let (created, createdPath) = try TestDatabase.createDatabaseManager()
        manager = created
        path = createdPath
        return created
    }

    /// One install's Inbox: the owner, today's and yesterday's day cards
    /// (today's only `withToday`), three tracks, three ideas, two messages
    /// and an automation card. Every time is set, never the real clock.
    private static func seed(_ db: Database, withToday: Bool) throws -> Seeded {
        try db.execute(sql: "INSERT INTO slack_accounts (id, current_user_id) VALUES (1, 'U001')")
        try TestDatabase.insertChannel(db, id: "C001", name: "eng")
        try TestDatabase.insertUser(db, id: "U002", name: "colleague-a", displayName: "Colleague A")
        try seedDays(db, withToday: withToday)
        let tracks = try seedTracks(db)
        let ideas = try seedIdeas(db)
        let message = try seedMessages(db)
        let automation = try TestDatabase.insertAutomation(db, slug: "mail-triage", name: "Morning mail triage",
                                                           outputsJSON: #"["inbox"]"#)
        let run = try TestDatabase.insertAutomationRun(db, automationID: automation)
        _ = try TestDatabase.insertAutomationOutput(
            db, automationID: automation, runID: run, title: "3 emails waiting for a reply",
            body: "From colleague A, colleague B and billing@example.com", createdAt: "2026-10-21T08:30:00Z")
        return Seeded(customTrack: tracks.custom, launchTrack: tracks.launch, stoppedTrack: tracks.stopped,
                      proposedIdea: ideas.proposed, decision: ideas.decision, message: message)
    }

    private static func seedDays(_ db: Database, withToday: Bool) throws {
        try TestDatabase.insertBriefing(
            db, date: yesterday, role: "Engineering lead · acme",
            attention: #"[{"text":"Sign off the acme v2 launch checklist","priority":"high"}]"#,
            readAt: "2026-10-20T08:00:00Z")
        try db.execute(sql: "UPDATE briefings SET created_at = '2026-10-20T07:00:00Z' WHERE date = ?",
                       arguments: [yesterday])
        guard withToday else { return }
        try TestDatabase.insertBriefing(
            db, date: today, role: "Engineering lead · acme",
            attention: #"[{"text":"Colleague A needs your review of the launch plan","priority":"high"},"#
                + #"{"text":"The acme refund is still waiting on finance","priority":"medium"}]"#,
            yourDay: #"[{"text":"Review the launch plan before Friday","priority":"high"}]"#,
            whatHappened: #"[{"text":"The eng channel agreed on a staged rollout for acme v2","channel_name":"eng"}]"#)
        try db.execute(sql: "UPDATE briefings SET created_at = '2026-10-21T07:00:00Z' WHERE date = ?",
                       arguments: [today])
        let plan = try TestDatabase.insertDayPlan(db, planDate: today, generatedAt: "2026-10-21T07:05:00Z")
        // Title, "HH:MM-HH:MM" UTC (none for the backlog), status.
        let items: [(String, String?, String)] = [
            ("Standup", "09:00-09:30", "done"),
            ("Review the acme launch plan", "10:00-11:00", "pending"),
            ("Write the rollout notes", "14:00-15:30", "pending"),
            ("Reply to billing@example.com", nil, "pending")
        ]
        for (index, item) in items.enumerated() {
            let times = item.1?.split(separator: "-").map { "\(today)T\($0):00Z" }
            try TestDatabase.insertDayPlanItem(
                db, dayPlanID: plan, kind: times == nil ? "backlog" : "timeblock", title: item.0,
                startTime: times?.first, endTime: times?.last, status: item.2, orderIndex: index)
        }
    }

    private static func seedTracks(_ db: Database) throws -> (custom: Int, launch: Int, stopped: Int) {
        let custom = try TestDatabase.insertTrack(db, text: "Watch the acme refund",
                                                  context: "Finance owes acme a refund for the October invoice.")
        try db.execute(sql: """
            UPDATE tracks SET origin = 'custom', enabled = 1, updated_at = '2026-10-21T09:40:00Z',
                instruction = 'Tell me when finance decides on the acme refund' WHERE id = ?
            """, arguments: [custom])
        let events: [(String, String?, String)] = [
            ("Finance asked acme for the original invoice", nil, "2026-10-21T09:30:00Z"),
            ("Colleague A says the refund is approved in principle", nil, "2026-10-21T08:10:00Z"),
            ("Acme sent the invoice again", "2026-10-20T09:00:00Z", "2026-10-20T08:00:00Z"),
            ("Finance opened a ticket for the refund", "2026-10-20T09:00:00Z", "2026-10-19T15:00:00Z"),
            ("Acme asked for a refund", "2026-10-20T09:00:00Z", "2026-10-19T10:00:00Z")
        ]
        for event in events {
            try db.execute(sql: """
                INSERT INTO track_events (track_id, summary, read_at, created_at) VALUES (?, ?, ?, ?)
                """, arguments: [custom, event.0, event.1, event.2])
        }
        let launch = try TestDatabase.insertTrack(
            db, text: "Launch of acme v2", context: "The rollout plan ships on Friday; colleague A owns QA.",
            priority: "high", hasUpdates: true)
        try db.execute(sql: "UPDATE tracks SET updated_at = '2026-10-21T08:00:00Z' WHERE id = ?", arguments: [launch])
        let stopped = try TestDatabase.insertTrack(db, text: "Old vendor migration",
                                                   context: "Moved off the old billing vendor at example.com.")
        try db.execute(sql: """
            UPDATE tracks SET dismissed_at = '2026-10-18T10:00:00Z', updated_at = '2026-10-18T10:00:00Z',
                read_at = '2026-10-18T10:00:00Z' WHERE id = ?
            """, arguments: [stopped])
        return (Int(custom), Int(launch), Int(stopped))
    }

    private static func seedIdeas(_ db: Database) throws -> (proposed: Int, decision: Int) {
        let proposed = try TestDatabase.insertIdea(
            db, title: "Ship a weekly digest email to acme leads",
            essence: "A short Friday email with what shipped and what is blocked.",
            createdAt: "2026-10-21T08:20:00Z", updatedAt: "2026-10-21T08:20:00Z")
        let decision = try TestDatabase.insertIdea(
            db, kind: "decision", title: "Use staged rollouts for every acme release",
            essence: "Agreed in #eng: 5 %, 25 %, then everyone, a day apart.", status: "active",
            createdAt: "2026-10-20T15:00:00Z", updatedAt: "2026-10-20T15:00:00Z")
        try TestDatabase.insertIdea(
            db, title: "Self-serve CSV import", essence: "Let acme admins import users without a ticket.",
            status: "active", createdAt: "2026-10-19T11:00:00Z", updatedAt: "2026-10-19T11:00:00Z")
        return (Int(proposed), Int(decision))
    }

    private static func seedMessages(_ db: Database) throws -> Int {
        let older = try TestDatabase.insertInboxItem(
            db, messageTS: "1700000000.000200", triggerType: "dm", snippet: "Lunch at noon tomorrow?",
            readAt: "2026-10-20T13:00:00Z")
        let message = try TestDatabase.insertInboxItem(
            db, snippet: "Can you review the launch plan before Friday? The rollout section changed.",
            permalink: "https://example.com/archives/C001/p1700000000000100", priority: "high",
            whyMatters: "You own the rollout; the plan ships Friday.",
            threadDigest: "Colleague A and colleague B agreed on a staged rollout.")
        for (id, at) in [(older, "2026-10-20T12:30:00Z"), (message, "2026-10-21T10:30:00Z")] {
            try db.execute(sql: "UPDATE inbox_items SET created_at = ? WHERE id = ?", arguments: [at, id])
        }
        return Int(message)
    }

    /// The shot renders at once, so the Inbox's async read is waited for
    /// here by running the main run loop (the test-side `spin` precedent).
    private static func refreshed(_ vm: ActionStripViewModel) {
        final class Flag { var done = false }
        let flag = Flag()
        Task { @MainActor in
            await vm.refresh()
            flag.done = true
        }
        let deadline = Date().addingTimeInterval(5)
        while !flag.done, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    private static func failure(_ error: Error) -> AnyView {
        XCTFail("one inbox shot fixture failed: \(error)")
        return AnyView(Text("fixture failed: \(String(describing: error))").foregroundStyle(.red))
    }
}
