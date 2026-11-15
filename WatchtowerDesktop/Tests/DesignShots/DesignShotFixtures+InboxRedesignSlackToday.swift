import GRDB
import SwiftUI
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The Inbox redesign, phase 5 (Slack today, #1076), drawn from the wired
/// views over a seeded test database (the `InboxRedesignShotFixtures`
/// pattern): the root with the Slack today row in Today (another entry
/// open), Slack today's pane, its pane the next morning (yesterday's list
/// and note), and the pane alone with the quiet channels' fold open.
/// Sample data only, at one fixed local time: the moments are built in the
/// machine's calendar (the Inbox reads `.autoupdatingCurrent`), so the
/// stale scene is the next morning — and draws its note — in every zone.
@MainActor
enum InboxSlackTodayShotFixtures {
    private static var paths: [String] = []
    private static var managers: [DatabaseManager] = []
    private static let defaultsSuite = "InboxSlackTodayShotFixtures"
    nonisolated static let now = localTime(day: 6, hour: 10, minute: 30)
    /// The next morning, for the stale scene.
    nonisolated static let nextMorning = localTime(day: 7, hour: 7, minute: 0)

    nonisolated private static func localTime(day: Int, hour: Int, minute: Int) -> Date {
        Calendar.autoupdatingCurrent.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour,
                                                               minute: minute)) ?? Date()
    }

    static func cleanUp() {
        managers = []
        paths.forEach(TestDatabase.cleanup(path:))
        paths = []
        UserDefaults().removePersistentDomain(forName: defaultsSuite)
    }

    enum Scene {
        case row, pane, stale
    }

    static var shots: [DesignShot] {
        let scenes: [(String, Scene)] = [
            ("inbox-r-slack-today-row", .row),
            ("inbox-r-slack-today-pane", .pane),
            ("inbox-r-slack-today-stale", .stale)
        ]
        return scenes.map { name, scene in
            DesignShot(name: name, size: NSSize(width: 1280, height: 760)) { view(scene) }
        } + [
            DesignShot(name: "inbox-r-slack-today-quiet-open", size: NSSize(width: 820, height: 900)) { quietOpen() }
        ]
    }

    // MARK: - The Inbox

    static func view(_ scene: Scene) -> AnyView {
        do {
            let (manager, path) = try TestDatabase.createDatabaseManager()
            managers.append(manager)
            paths.append(path)
            let clock = scene == .stale ? nextMorning : now
            let seeded = try manager.dbPool.write { db in try seed(db, clock: clock) }
            let defaults = UserDefaults(suiteName: defaultsSuite) ?? .standard
            defaults.removePersistentDomain(forName: defaultsSuite)
            // Labeled: a trailing closure would bind to `automationsWake`.
            // swiftlint:disable trailing_closure
            let vm = ActionStripViewModel(dbPool: manager.dbPool, cliRunner: FakeCLIRunner(), defaults: defaults,
                                          clock: { clock })
            // swiftlint:enable trailing_closure
            let entry = scene == .row ? "artifact:\(seeded.weekly)" : "artifact:\(seeded.slack)"
            run("the entry", vm) {
                await vm.selectEntry(entry)
                await vm.arrival?.value
            }
            XCTAssertEqual(vm.entrySelection, entry)
            let today = vm.folderList.sections.first { $0.id == InboxRootSection.today.rawValue }
            XCTAssertEqual(today?.rows.first?.content.kind, .slackToday, "Slack today is in Today")
            let appState = AppState()
            appState.databaseManager = manager
            var inbox = ActionStripActionsView(
                vm: vm, cheatSheetRows: [], feature: .on(lastCheck: nil), isEnabling: false, featureError: nil,
                onEnable: {}, onOpenSettings: {}, onOpen: { _ in }, onRetryBuiltin: { _ in }, now: clock
            )
            inbox.artifactMenu = artifactMenu(manager.dbPool, vm, seeded.automation)
            return AnyView(inbox
                .environment(appState)
                .environment(\.markdownNavScreens, ["home"])
                .detailBackground())
        } catch {
            return DesignShotFixtures.failure(error)
        }
    }

    /// The pane alone, its card's blocks drawn, the quiet fold open.
    static func quietOpen() -> AnyView {
        let state = SlackTodayState.decode(stateJSON: stateJSON(day: dayString(now)))
        guard state.summary != nil else {
            return DesignShotFixtures.failure(FixtureError.badState)
        }
        let card = AutomationOutputCard(
            id: 1, automationID: 1, automationName: "Slack today", runID: 4, title: "Slack today", body: "",
            priority: "medium", createdAt: now, readAt: now, blocksJSON: blocksJSON, outputKey: "slack-today",
            contentHash: "h1", writtenAt: now, changedAt: now)
        let menu = InboxArtifactMenuState(entries: InboxArtifactMenuContent(isBuiltin: true).entries)
        let pane = SlackTodayPane(card: card, state: state, now: now, calendar: .autoupdatingCurrent, menu: menu,
                                  onMarkAllSeen: {}, onReactionCommands: {}, quietShown: true)
            .drawing(ArtifactCardBody(blocksJSON: blocksJSON, actionsJSON: "[]", text: "", mode: .inbox))
        return AnyView(InboxCardColumn { pane }.detailBackground())
    }

    /// The Inbox's artifact ⋯ over an Automations tab that knows Slack
    /// today as a built-in offering Run Now (its `show` answered by a fake
    /// CLI), read before the shot so the pane draws Run Now and the ⋯.
    private static func artifactMenu(
        _ pool: DatabasePool,
        _ vm: ActionStripViewModel,
        _ automationID: Int64
    ) -> InboxArtifactMenuModel {
        let slug = SlackTodayQueries.builtinID
        let show = "{\"id\":\(automationID),\"slug\":\"\(slug)\",\"scope\":\"personal\",\"path\":\"builtin:\(slug)\","
            + "\"name\":\"Slack today\",\"enabled\":true,\"runnable\":true,\"needs_confirmation\":false,"
            + "\"recipe_text\":\"\",\"builtin\":{\"id\":\"\(slug)\",\"feature_ids\":[\"\(slug)\"],"
            + "\"enabled\":true,\"run_now\":true}}"
        let automations = AutomationsViewModel(
            dbPool: pool, cli: AutomationsCLI(runner: FakeCLIRunner(stdout: Data(show.utf8))),
            defaults: UserDefaults(suiteName: defaultsSuite) ?? .standard)
        automations.refresh()
        let menu = InboxArtifactMenuModel(folderMenu: vm.folderMenu, hooks: .init(
            automations: { automations }, setBuiltinEnabled: { _, _ in nil }, openEditor: { _, _ in },
            openRunHistory: { _ in }, refresh: {}))
        if let card = vm.folderEntries.lazy.compactMap({ entry -> AutomationOutputCard? in
            if case let .artifact(card) = entry, card.automationID == automationID { return card }
            return nil
        }).first {
            run("the ⋯", vm) { await menu.prepare(card) }
        }
        return menu
    }

    /// A read, `step`, one more read — each awaited to its end.
    private static func run(_ what: String, _ vm: ActionStripViewModel, _ step: @escaping @MainActor () async -> Void) {
        let finished = Finished()
        InboxFolderMenuShotFixtures.spin(until: what, finished.value) {
            await vm.refresh()
            await step()
            await vm.refresh()
            finished.value = true
        }
    }

    // MARK: - The database

    private enum FixtureError: Error {
        case badState
    }

    struct Seeded {
        let slack: Int64
        let weekly: Int64
        let automation: Int64
    }

    private static func dayString(_ date: Date) -> String {
        HomeFeedBuilder.dayString(date, calendar: .autoupdatingCurrent)
    }

    private static func at(_ clock: Date, minutesAgo: Int) -> String {
        AutomationDates.format(clock.addingTimeInterval(TimeInterval(-60 * minutesAgo)))
    }

    /// The root and Needs approval; Slack today's built-in with today's
    /// state (written yesterday evening for the stale scene) and its living
    /// card; an owner artifact from today and one older.
    private static func seed(_ db: Database, clock: Date) throws -> Seeded {
        try db.execute(sql: "INSERT INTO inbox_folders (kind, parent_id, slug, title, position) VALUES ('root', NULL, 'inbox', 'Inbox', 0)")
        let root = db.lastInsertedRowID
        try db.execute(sql: """
            INSERT INTO inbox_folders (kind, parent_id, slug, title, position)
            VALUES ('approvals', ?, 'needs-approval', 'Needs approval', 0)
            """, arguments: [root])
        try db.execute(sql: "INSERT INTO inbox_folder_state (id, revision) VALUES (1, 1)")

        // The stale scene: the card and state are from the evening before `clock`.
        let written = clock == nextMorning ? at(clock, minutesAgo: 600) : at(clock, minutesAgo: 10)
        let stateDay = dayString(clock == nextMorning ? clock.addingTimeInterval(-600 * 60) : clock)
        let slack = try TestDatabase.insertAutomation(db, slug: SlackTodayQueries.builtinID, name: "Slack today")
        try db.execute(sql: "UPDATE automations SET origin = 'builtin', builtin_id = ?, path = ? WHERE id = ?",
                       arguments: [SlackTodayQueries.builtinID, "builtin:\(SlackTodayQueries.builtinID)", slack])
        let run = try TestDatabase.insertAutomationRun(db, automationID: slack)
        try db.execute(sql: "INSERT INTO automation_state (automation_id, state_json, run_id) VALUES (?, ?, ?)",
                       arguments: [slack, stateJSON(day: stateDay), run])
        let card = try TestDatabase.insertAutomationOutput(
            db, automationID: slack, runID: run, title: "Slack today", body: "#acme-release decided the tag date.",
            createdAt: written, blocksJSON: blocksJSON, outputKey: "slack-today", contentHash: "h1",
            writtenAt: written, changedAt: written)

        let blockers = try TestDatabase.insertAutomation(db, slug: "release-blockers", name: "Release blockers")
        let blockersRun = try TestDatabase.insertAutomationRun(db, automationID: blockers)
        try TestDatabase.insertAutomationOutput(
            db, automationID: blockers, runID: blockersRun, title: "Release blockers",
            body: "Two open blockers. QA signs off Friday.",
            createdAt: at(clock, minutesAgo: 25), writtenAt: at(clock, minutesAgo: 25),
            changedAt: at(clock, minutesAgo: 25))
        let weeklyAutomation = try TestDatabase.insertAutomation(db, slug: "weekly-mail", name: "Weekly mail roundup")
        let weeklyRun = try TestDatabase.insertAutomationRun(db, automationID: weeklyAutomation)
        let weekly = try TestDatabase.insertAutomationOutput(
            db, automationID: weeklyAutomation, runID: weeklyRun, title: "Weekly mail roundup",
            body: "Three threads from example.com need an answer this week.",
            createdAt: at(clock, minutesAgo: 2 * 1440), readAt: at(clock, minutesAgo: 2 * 1440 - 30),
            writtenAt: at(clock, minutesAgo: 2 * 1440), changedAt: at(clock, minutesAgo: 2 * 1440))
        return Seeded(slack: card, weekly: weekly, automation: slack)
    }

    /// 900 messages in 46 conversations (a DM and a group DM among them):
    /// four with news, 42 with nothing for the owner (two of them folded by
    /// the state): 80 + 816 + 4 messages, the fold 820 as in the mockup.
    private static func stateJSON(day: String) -> String {
        func line(_ label: String, _ text: String, _ time: String) -> String {
            #"{"label":"\#(label)","text":"\#(text)","at":"\#(day)T\#(time):00Z","link":"https://acme.slack.com/archives/C1/p1"}"#
        }
        var channels = [
            #""C1":{"name":"acme-release","n":23,"more":0,"lines":["#
                + line("decided", "The tag goes out Thursday, after QA signs off.", "09:10") + ","
                + line("asks_you", "Colleague A asks whether Thursday works for your side.", "09:20") + "]}",
            #""C2":{"name":"acme-infra","n":38,"more":0,"lines":["#
                + line("needs_someone", "Colleague D is looking for a reviewer for the DB migration.", "09:30") + ","
                + line("fyi", "Staging was down 20 min at 09:40; fixed.", "09:45") + "]}",
            #""C3":{"name":"acme-finance","n":7,"more":0,"lines":["#
                + line("fyi", "Budget 2027 numbers are final; the file is pinned.", "08:30") + "]}",
            #""C4":{"name":"acme-design","n":12,"more":2,"link":"https://acme.slack.com/archives/C4/p1"}"#,
            #""D1":{"name":"@Colleague B","n":30}"#,
            #""G1":{"name":"Colleague B, Colleague C","n":22}"#
        ]
        let quiet = [("acme-random", 313), ("acme-music", 120), ("acme-watercooler", 96), ("acme-bots", 99)]
            + (1...34).map { (String(format: "acme-team-%02d", $0), 4) }
        channels += quiet.enumerated().map { index, channel in #""Q\#(index)":{"name":"\#(channel.0)","n":\#(channel.1)}"# }
        return #"{"today":{"v":1,"day":"\#(day)","messages":900,"missed_earlier":0,"skipped_older":0,"channels":{"#
            + channels.joined(separator: ",")
            + #"},"quiet_rest":{"channels":2,"messages":4},"more_rest":{"channels":0,"lines":0}}}"#
    }

    /// The card the recipe draws from that state (`blocksOf`).
    private static let blocksJSON: String = {
        func row(_ title: String, _ text: String, _ tone: String) -> String {
            #"{"title":"\#(title)","badge":{"text":"\#(text)","tone":"\#(tone)"},"link":"https://acme.slack.com/archives/C1/p1"}"#
        }
        func channel(_ name: String, _ rows: [String], link: String) -> String {
            #"{"type":"list","title":"\#(name)","rows":["# + rows.joined(separator: ",") + "]},"
                + #"{"type":"link","title":"Open in Slack","url":"\#(link)"}"#
        }
        let blocks = [
            channel("#acme-release", [
                row("Colleague A asks whether Thursday works for your side.", "asks you", "warning"),
                row("The tag goes out Thursday, after QA signs off.", "decided", "success")
            ], link: "https://acme.slack.com/archives/C1/p1"),
            channel("#acme-infra", [
                row("Colleague D is looking for a reviewer for the DB migration.", "needs someone", "info"),
                row("Staging was down 20 min at 09:40; fixed.", "fyi", "neutral")
            ], link: "https://acme.slack.com/archives/C2/p1"),
            channel("#acme-finance", [row("Budget 2027 numbers are final; the file is pinned.", "fyi", "neutral")],
                    link: "https://acme.slack.com/archives/C3/p1"),
            // `##`: the title's `"#` would end a one-`#` raw string.
            ##"{"type":"list","title":"#acme-design","rows":[{"title":"2 more lines — open the channel to "##
                + ##"read them","link":"https://acme.slack.com/archives/C4/p1"}]},"##
                + #"{"type":"link","title":"Open in Slack","url":"https://acme.slack.com/archives/C4/p1"}"#
        ]
        return #"{"v":1,"blocks":["# + blocks.joined(separator: ",") + "]}"
    }()
}

/// A step that ran to its end.
@MainActor
private final class Finished {
    var value = false
}
