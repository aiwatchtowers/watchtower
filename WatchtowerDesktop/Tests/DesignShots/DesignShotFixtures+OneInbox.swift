import GRDB
import SwiftUI
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport
@testable import ChatUI

/// The one Inbox (C1) since its filters went (inbox builder B): today's day
/// card in the root, and the root's legacy lists — a custom track and an
/// extracted one, ideas and a decision, a message — each opened through the
/// view model's own route (`open(folder:select:)`), over one fixed moment
/// (2026-10-21 12:00 UTC) handed to the view model's clock and the list, so
/// Today, Earlier and the day labels never move with the real date.
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
    private static let owner = Owner(
        id: "1:U001", source: .slack, slackUserID: "1:U001", email: "", jiraAccountID: "", displayName: "Me"
    )

    /// What a shot opens, and which rows its database holds.
    struct Scene {
        /// What the route opens; nil = the root with nothing open.
        var route: (Seeded) -> InboxRoute.Entry? = { _ in nil }
        var withToday = true
        var showsStopped = false
        var dayRow: InboxDayPlanRow?
        var ideasRow: InboxIdeasRow?
        var aux: InboxAuxPane?
        /// A built-in's failed move to Automations (C2) in the database.
        var builtinNotice = false
        /// The custom track's watch (C3).
        var watch: WatchScene = .legacy
        /// A decision proposed from a chat, with its chat mention, opened.
        var chatDecision = false
        /// The card the route opens is marked read by the opening: the
        /// case whose step lists it read once that write landed.
        var opens: Opens?
    }

    /// A route that marks its card read.
    enum Opens { case day, message }

    /// The custom track before the custom-tracks move (C1's controls), bound
    /// to a watch recipe (as shipped, or changed in the chat), or unbound
    /// after the move.
    enum WatchScene { case legacy, bound, edited, unbound }

    private static func watchJSON(templateShaped: Bool) -> Data {
        Data(#"""
            {"watch":{"track_id":1,"instruction":"Tell me when finance decides on the acme refund",
             "template_shaped":\#(templateShaped)}}
            """#.utf8)
    }

    /// The ids the cases' seed writes.
    struct Seeded {
        let customTrack = 1
        let launchTrack = 2
        let stoppedTrack = 3
        let proposedIdea = 1
        let decision = 2
        let message = 2
        /// The decision a chat proposed (`desktop_shot_one_inbox_chat_decision`).
        let chatDecision = 4
    }

    // MARK: - Shots

    static func dayCard() async -> AnyView { await inbox(Scene(route: { _ in .card(.day(today)) }, opens: .day)) }
    static func dayCardRegenerate() async -> AnyView {
        await inbox(Scene(route: { _ in .card(.day(today)) }, dayRow: .regenerate, opens: .day))
    }
    static func dayCardEmpty() async -> AnyView {
        await inbox(Scene(route: { _ in .card(.day(today)) }, withToday: false))
    }
    static func trackCard() async -> AnyView { await inbox(Scene { .card(.track($0.customTrack)) }) }
    static func trackCard(_ watch: WatchScene) async -> AnyView {
        await inbox(Scene(route: { .card(.track($0.customTrack)) }, watch: watch))
    }
    static func tracksStopped() async -> AnyView {
        await inbox(Scene(route: { .card(.track($0.stoppedTrack)) }, showsStopped: true))
    }
    static func ideaCard() async -> AnyView { await inbox(Scene { .card(.idea($0.proposedIdea)) }) }
    static func decisionCard() async -> AnyView { await inbox(Scene { .card(.idea($0.decision)) }) }
    static func chatDecisionCard() async -> AnyView { await inbox(Scene(chatDecision: true)) }
    static func ideasNew() async -> AnyView {
        await inbox(Scene(route: { .card(.idea($0.proposedIdea)) }, ideasRow: .newIdea))
    }
    static func messageCard() async -> AnyView { await inbox(Scene(route: { .card(.message($0.message)) }, opens: .message)) }
    static func cheatSheet() async -> AnyView { await inbox(Scene(aux: .reactionCommands)) }
    static func builtinNotice() async -> AnyView {
        await inbox(Scene(route: { _ in .card(.builtinNotice("morning-brief")) }, builtinNotice: true))
    }

    /// Today's day card alone at the reading pane's narrowest (420 pt).
    static func dayCardNarrow() -> AnyView {
        do {
            let manager = try freshDatabase()
            _ = try InboxShotFeed.seeded("desktop_shot_one_inbox_default", manager.dbPool)
            let card = try XCTUnwrap(manager.dbPool.read { db in
                try BriefingQueries.fetchDayCards(db, limit: 1).first
            })
            let plan = DayPlanViewModel(databasePool: manager.dbPool, cliRunner: FakeCLIRunner(), tower: manager.fakeTower)
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

    private static func inbox(_ scene: Scene) async -> AnyView {
        do {
            let manager = try freshDatabase()
            let tower = try InboxShotFeed.seeded(caseName(scene), manager.dbPool)
            let seeded = Seeded()
            let defaults = UserDefaults(suiteName: defaultsSuite) ?? .standard
            defaults.removePersistentDomain(forName: defaultsSuite)
            let clock = now
            // Labeled: a trailing closure would bind to `automationsWake`.
            // swiftlint:disable trailing_closure
            let vm = ActionStripViewModel(dbPool: manager.dbPool, cliRunner: FakeCLIRunner(),
                                          defaults: defaults, clock: { clock })
            // swiftlint:enable trailing_closure
            vm.showsStopped = scene.showsStopped
            await InboxShotFeed.listed(vm, tower) {
                await vm.open(folder: nil, select: scene.chatDecision ? .card(.idea(seeded.chatDecision)) : scene.route(seeded))
            }
            let plan = DayPlanViewModel(databasePool: manager.dbPool, cliRunner: FakeCLIRunner(), tower: manager.fakeTower)
            let ideas = IdeasViewModel(dbManager: manager, cliRunner: FakeCLIRunner())
            let appState = AppState()
            appState.databaseManager = manager
            appState.embeddedChats.dbPool = manager.dbPool
            appState.trackActionRunnerOverride = FakeCLIRunner(stdout: watchJSON(templateShaped: scene.watch != .edited))
            return AnyView(ActionStripActionsView(
                vm: vm, cheatSheetRows: cheatSheetRows, feature: .on(lastCheck: nil),
                isEnabling: false, featureError: nil, onEnable: {}, onOpenSettings: {}, onOpen: { _ in },
                dayPane: { card in dayPane(card, manager: manager, plan: plan, row: scene.dayRow) },
                ideas: ideas,
                ideaPane: { idea in
                    var pane = InboxIdeaPane(idea: idea, ideas: ideas, allIdeas: vm.feed.ideas)
                    pane.now = clock // a fixed moment: the ages never move with the real date
                    return pane
                },
                onRetryBuiltin: { _ in },
                tracks: TracksViewModel(dbManager: manager, tower: manager.fakeTower),
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

    /// The Go desktop case holding `scene`'s database: the owner, today's
    /// and yesterday's day cards (today's only `withToday`), three tracks,
    /// three ideas, two messages and an automation card; the custom track
    /// bound to a watch recipe or moved, a built-in's failed move, a decision
    /// a chat proposed, as the scene asks. Every time is set, never the real clock.
    private static func caseName(_ scene: Scene) -> String {
        "desktop_shot_one_inbox_" + {
            if scene.chatDecision { return "chat_decision" }
            if scene.opens == .day { return "day_opened" }
            if scene.opens == .message { return "message_opened" }
            if scene.builtinNotice { return "builtin_notice" }
            if scene.watch == .unbound { return "watch_unbound" }
            if scene.watch != .legacy { return "watch_bound" }
            return scene.withToday ? "default" : "no_today"
        }()
    }

    private static func dayPane(
        _ card: InboxDayCard, manager: DatabaseManager, plan: DayPlanViewModel, row: InboxDayPlanRow?
    ) -> InboxDayPane {
        var pane = InboxDayPane(card: card, today: today, plan: plan, owner: owner,
                                onCommand: { _ in }, onOpenSource: { _ in })
        pane.briefing = BriefingViewModel(dbManager: manager, cliRunner: FakeCLIRunner())
        pane.emptyState = EmptyStateContext(readiness: { _ in .ready }, briefingHour: 8)
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

    private static func failure(_ error: Error) -> AnyView {
        XCTFail("one inbox shot fixture failed: \(error)")
        return AnyView(Text("fixture failed: \(String(describing: error))").foregroundStyle(.red))
    }
}
