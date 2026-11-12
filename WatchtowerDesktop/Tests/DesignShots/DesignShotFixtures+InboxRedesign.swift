import GRDB
import SwiftUI
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The Inbox redesign, phase 1 (the Desktop shell, #1076), drawn from the
/// wired views over a seeded test database (the `InboxApprovalsShotFixtures`
/// pattern): the three columns of `ActionStripActionsView` — the root with
/// every section and today's brief open, the rail hidden, the brief on a
/// past day and with History open, Needs approval's groups and a partial
/// **Approve All**, an owner folder, a search that finds nothing — and the
/// app sidebar with the Inbox at the root. Every state is reached through
/// the view model's public API. Sample data only, at one fixed moment.
@MainActor
enum InboxRedesignShotFixtures {
    private static var paths: [String] = []
    private static var managers: [DatabaseManager] = []
    private static let defaultsSuite = "InboxRedesignShotFixtures"
    nonisolated static let now = AutomationDates.parse("2026-11-06T12:00:00Z") ?? Date()

    static func cleanUp() {
        managers = []
        paths.forEach(TestDatabase.cleanup(path:))
        paths = []
        UserDefaults().removePersistentDomain(forName: defaultsSuite)
    }

    private static let owner = Owner(
        id: "1:U001", source: .slack, slackUserID: "1:U001", email: "", jiraAccountID: "", displayName: "Me"
    )
    private static var today: String { day(daysAgo: 0) }
    /// The past day the stepper shows (the newest past brief).
    private static var pastDay: String { day(daysAgo: 1) }

    /// "yyyy-MM-dd" `daysAgo` days before `now`, in the calendar the Inbox's days follow.
    private static func day(daysAgo: Int) -> String {
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: now) ?? now
        return HomeFeedBuilder.dayString(date, calendar: .current)
    }

    private static func at(minutesAgo: Int) -> String {
        AutomationDates.format(now.addingTimeInterval(TimeInterval(-60 * minutesAgo)))
    }

    /// What one shot opens.
    enum Scene {
        case root, railHidden, briefPastDay, briefHistory, approvalsGroups, approveAllPartial, ownerFolder,
             searchNoMatch
    }

    /// The error the partial **Approve All** stopped on.
    static let partialError = "The track “acme refund” could not be created: the channel #acme-finance was archived."

    static var shots: [DesignShot] {
        let scenes: [(String, CGFloat, Scene)] = [
            ("inbox-r-root", 760, .root),
            ("inbox-r-root-rail-hidden", 760, .railHidden),
            ("inbox-r-brief-past-day", 760, .briefPastDay),
            ("inbox-r-brief-history", 760, .briefHistory),
            ("inbox-r-approvals-groups", 760, .approvalsGroups),
            ("inbox-r-approve-all-partial", 760, .approveAllPartial),
            ("inbox-r-owner-folder", 640, .ownerFolder),
            ("inbox-r-search-no-match", 640, .searchNoMatch)
        ]
        return scenes.map { name, height, scene in
            DesignShot(name: name, size: NSSize(width: 1280, height: height)) { view(scene) }
        } + [
            DesignShot(name: "inbox-r-sidebar", size: NSSize(width: 240, height: 720)) { sidebar() }
        ]
    }

    // MARK: - The Inbox

    /// The Inbox over a fresh seed, opened at `scene`.
    static func view(_ scene: Scene) -> AnyView {
        do {
            let (manager, path) = try TestDatabase.createDatabaseManager()
            managers.append(manager)
            paths.append(path)
            let folders = try manager.dbPool.write { db in try seed(db) }
            let defaults = UserDefaults(suiteName: defaultsSuite) ?? .standard
            defaults.removePersistentDomain(forName: defaultsSuite)
            let clock = now
            // Labeled: a trailing closure would bind to `automationsWake`.
            // swiftlint:disable trailing_closure
            let vm = ActionStripViewModel(dbPool: manager.dbPool, cliRunner: FakeCLIRunner(), defaults: defaults,
                                          clock: { clock })
            // swiftlint:enable trailing_closure
            open(scene, vm: vm, folders: folders)
            let plan = DayPlanViewModel(databasePool: manager.dbPool, cliRunner: FakeCLIRunner())
            let briefing = BriefingViewModel(dbManager: manager, cliRunner: FakeCLIRunner())
            let appState = AppState()
            appState.databaseManager = manager
            let inbox = ActionStripActionsView(
                vm: vm, cheatSheetRows: [], feature: .on(lastCheck: nil), isEnabling: false, featureError: nil,
                onEnable: {}, onOpenSettings: {}, onOpen: { _ in },
                dayPane: { card, _ in
                    var pane = InboxDayPane(card: card, today: today, plan: plan, owner: owner,
                                            onCommand: { _ in }, onOpenSource: { _ in })
                    pane.briefing = briefing
                    pane.emptyState = EmptyStateContext(readiness: { _ in .ready }, briefingHour: 8)
                    return pane
                },
                onRetryBuiltin: { _ in },
                now: now
            )
            return AnyView(Group {
                if scene == .briefHistory {
                    // A popover does not render in a shot: History's list
                    // stands where it opens, under the pane header.
                    inbox.overlay(alignment: .topTrailing) { historyStandIn(vm) }
                } else {
                    inbox
                }
            }
            .environment(appState)
            .environment(\.markdownNavScreens, ["home"])
            .detailBackground())
        } catch {
            return DesignShotFixtures.failure(error)
        }
    }

    /// Drives `vm` to `scene` through its public API. Each step runs to its
    /// end — the owner's arrival and its read mark included — and one more
    /// read follows, so light and dark draw the same state.
    private static func open(_ scene: Scene, vm: ActionStripViewModel, folders: Folders) {
        let brief = "day:\(today)"
        switch scene {
        case .root, .railHidden, .searchNoMatch:
            run("today's brief", vm) { await vm.selectEntry(brief) }
            XCTAssertEqual(vm.entrySelection, brief)
            XCTAssertEqual(vm.folderList.sections.map(\.title), ["Needs you", "Today", "Running"])
            if scene == .railHidden { vm.railHidden = true }
            if scene == .searchNoMatch { vm.listQuery = "zebra budget" }
        case .briefPastDay:
            run("the past day", vm) { await vm.showBriefDay(pastDay) }
            XCTAssertEqual(vm.briefDate, pastDay)
        case .briefHistory:
            run("History", vm) { vm.openBriefHistory() }
            XCTAssertTrue(vm.briefHistoryShown)
        case .approvalsGroups, .approveAllPartial:
            // The owner's click on the group row: the stack scrolls to its
            // header, where **Approve All 3…** is.
            let group = NeedsApprovalGroups.rowID(.tracksToCreate)
            run("the Needs approval read", vm) {
                vm.selectFolder(folders.approvals)
                await vm.arrival?.value
                await vm.selectEntry(group)
            }
            XCTAssertEqual(vm.folderEntries.count, 6)
            XCTAssertEqual(vm.entrySelection, group)
            if scene == .approveAllPartial { pressPartial(vm.approveAllModel(.tracksToCreate)) }
        case .ownerFolder:
            run("the owner folder", vm) {
                vm.selectFolder(folders.release)
                await vm.arrival?.value
            }
            XCTAssertEqual(vm.folderList.sections.map(\.title), ["Today", "Earlier"])
        }
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

    /// **Approve All 3…** pressed, confirmed and stopped after the first:
    /// the model's own plan → confirm → apply with fake closures (no CLI).
    private static func pressPartial(_ model: InboxBulkPressModel) {
        InboxFolderMenuShotFixtures.spin(until: "the confirmation", model.state.isConfirming) {
            model.begin { InboxBulkPlan(ids: ["1", "2", "3"], count: 3) }
        }
        let result = InboxBulkResult.partial(done: 1, of: 3, error: partialError)
        InboxFolderMenuShotFixtures.spin(until: "the partial result", model.state == .finished(result)) {
            model.confirm { _ in result }
        }
    }

    /// History's list where its popover opens.
    private static func historyStandIn(_ vm: ActionStripViewModel) -> some View {
        let calendar = Calendar.autoupdatingCurrent
        let days = InboxBriefDays.history(vm.feed.days, today: today, now: now, calendar: calendar)
        return InboxBriefHistoryList(days: days, shownDate: today) { _ in }
            .fixedSize()
            .popoverSurface()
            // The popover's own material and shadow, which a shot cannot draw.
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.12)))
            .shadow(color: FloatingShadow.color, radius: FloatingShadow.radius, y: FloatingShadow.y)
            .padding(.top, 52)
            .padding(.trailing, 110)
    }

    // MARK: - The sidebar

    /// The app sidebar on the Inbox: the Inbox at the root, Targets in FOCUS.
    /// Its badges come from AppState's sidebar counts, which only the app's
    /// launch builds, so the shot draws the rows without them.
    /// The sidebar over the Inbox's seed, its badge counted from it.
    static func sidebar() -> AnyView {
        do {
            let (manager, path) = try TestDatabase.createDatabaseManager()
            managers.append(manager)
            paths.append(path)
            _ = try manager.dbPool.write { db in try seed(db) }
            let clock = now
            // Labeled: a trailing closure would bind to `sleepUntil`.
            // swiftlint:disable:next trailing_closure
            let counts = SidebarCountsViewModel(dbPool: manager.dbPool, clock: { clock })
            let finished = Finished()
            InboxFolderMenuShotFixtures.spin(until: "the sidebar counts", finished.value) {
                await counts.loadInitial()
                finished.value = true
            }
            XCTAssertGreaterThan(counts.inboxStripCount, 0, "the Inbox badge has something to show")
            let appState = AppState()
            appState.databaseManager = manager
            appState.useSidebarCounts(counts)
            return AnyView(SidebarView(selection: .constant(.inbox))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .environment(appState))
        } catch {
            return DesignShotFixtures.failure(error)
        }
    }

    // MARK: - The database

    struct Folders {
        let approvals: Int64
        let release: Int64
    }

    /// The tree (root, Needs approval, the owner's "Release acme 2.0");
    /// Waiting for me with three pings; today's brief and plan and three
    /// past briefs (one never opened); an artifact changed today and one
    /// older; two tracks and an idea; three Slack messages and three tracks
    /// to create waiting for approval; two artifacts in the owner folder,
    /// one from today and one older.
    private static func seed(_ db: Database) throws -> Folders {
        // The migration's seed rows (the test schema is DDL only); the
        // Desktop itself never writes these tables.
        let root = try folder(db, kind: "root", parent: nil, slug: "inbox", title: "Inbox")
        let approvals = try folder(db, kind: "approvals", parent: root, slug: "needs-approval", title: "Needs approval")
        try db.execute(sql: "INSERT INTO inbox_folder_state (id, revision) VALUES (1, 1)")
        let release = try folder(db, kind: "owner", parent: root, slug: "release", title: "Release acme 2.0",
                                 icon: "flag")
        _ = try TestDatabase.insertSlackAccount(db, currentUserID: "1:U001")
        try TestDatabase.insertChannel(db, id: "C001", name: "acme-release")
        try TestDatabase.insertUser(db, id: "U002", name: "colleague-a", displayName: "Colleague A")

        try seedWaiting(db)
        try seedDays(db)
        try seedRunning(db)
        try seedApprovals(db)
        try seedOwnerFolder(db, folder: release)
        return Folders(approvals: approvals, release: release)
    }

    private static func seedWaiting(_ db: Database) throws {
        var pings: [Int64] = []
        let asks = [("Can you check the release checklist?", 25), ("Will you approve the acme budget?", 50),
                    ("Who reviews the migration?", 95)]
        for (index, (text, minutes)) in asks.enumerated() {
            let id = try TestDatabase.insertInboxItem(db, messageTS: "1762400000.00010\(index)", snippet: text)
            try db.execute(sql: "UPDATE inbox_items SET created_at = ? WHERE id = ?",
                           arguments: [at(minutesAgo: minutes), id])
            pings.append(id)
        }
        let waiting = try builtin(db, id: "waiting-for-me", name: "Waiting for me")
        let run = try TestDatabase.insertAutomationRun(db, automationID: waiting)
        let rows = zip(pings, asks).map { id, ask in
            #"{"title":"Colleague A: \#(ask.0)","ref":{"kind":"inbox_item","id":\#(id)}}"#
        }
        try TestDatabase.insertAutomationOutput(
            db, automationID: waiting, runID: run, title: "Waiting for me", body: "",
            createdAt: at(minutesAgo: 6), blocksJSON: #"{"v":1,"blocks":[{"type":"list","rows":["#
                + rows.joined(separator: ",") + "]}]}",
            outputKey: "waiting", writtenAt: at(minutesAgo: 6), changedAt: at(minutesAgo: 6))
    }

    private static func seedDays(_ db: Database) throws {
        try TestDatabase.insertBriefing(
            db, userID: "1:U001", date: today, role: "Engineering lead · acme",
            attention: #"[{"text":"Colleague A needs your review of the acme 2.0 checklist","priority":"high"},"#
                + #"{"text":"The acme refund is still waiting on finance","priority":"medium"}]"#,
            yourDay: #"[{"text":"Review the release checklist before the 15:00 sync","priority":"high"}]"#,
            whatHappened: #"[{"text":"The release channel agreed on a staged rollout","channel_name":"acme-release"}]"#)
        let pastTopics = [(1, "Sign off the acme 2.0 checklist", true), (2, "Answer billing@example.com", false),
                          (4, "Plan the acme offsite", true)]
        for (daysAgo, text, read) in pastTopics {
            try TestDatabase.insertBriefing(
                db, userID: "1:U001", date: day(daysAgo: daysAgo), role: "Engineering lead · acme",
                attention: #"[{"text":"\#(text)","priority":"high"}]"#,
                readAt: read ? at(minutesAgo: daysAgo * 1440 - 60) : nil)
        }
        for daysAgo in [0, 1, 2, 4] {
            try db.execute(sql: "UPDATE briefings SET created_at = ? WHERE date = ?",
                           arguments: [at(minutesAgo: daysAgo * 1440 + 300), day(daysAgo: daysAgo)])
        }
        let plan = try TestDatabase.insertDayPlan(db, userID: "1:U001", planDate: today,
                                                  generatedAt: at(minutesAgo: 295))
        let items: [(String, String?, String)] = [
            ("Standup", "09:00-09:30", "done"),
            ("Review the acme 2.0 checklist", "13:00-14:00", "pending"),
            ("Reply to billing@example.com", nil, "pending")
        ]
        for (index, item) in items.enumerated() {
            let times = item.1?.split(separator: "-").map { "\(today)T\($0):00Z" }
            try TestDatabase.insertDayPlanItem(
                db, dayPlanID: plan, kind: times == nil ? "backlog" : "timeblock", title: item.0,
                startTime: times?.first, endTime: times?.last, status: item.2, orderIndex: index)
        }
    }

    /// Slack today's built-in with a small state of today and its living
    /// card, an older weekly roundup, two tracks, one idea.
    private static func seedRunning(_ db: Database) throws {
        let slack = try TestDatabase.insertAutomation(db, slug: SlackTodayQueries.builtinID, name: "Slack today")
        try db.execute(sql: "UPDATE automations SET origin = 'builtin', builtin_id = ?, path = ? WHERE id = ?",
                       arguments: [SlackTodayQueries.builtinID, "builtin:\(SlackTodayQueries.builtinID)", slack])
        let slackRun = try TestDatabase.insertAutomationRun(db, automationID: slack)
        try db.execute(sql: "INSERT INTO automation_state (automation_id, state_json, run_id) VALUES (?, ?, ?)",
                       arguments: [slack, slackTodayState, slackRun])
        try TestDatabase.insertAutomationOutput(
            db, automationID: slack, runID: slackRun, title: "Slack today",
            body: "#acme-release: colleague A asks whether Thursday works for your side.",
            createdAt: at(minutesAgo: 40), blocksJSON: slackTodayBlocks, outputKey: "slack-today",
            contentHash: "h1", writtenAt: at(minutesAgo: 40), changedAt: at(minutesAgo: 40))
        let weekly = try TestDatabase.insertAutomation(db, slug: "weekly-mail", name: "Weekly mail roundup")
        let weeklyRun = try TestDatabase.insertAutomationRun(db, automationID: weekly)
        try TestDatabase.insertAutomationOutput(
            db, automationID: weekly, runID: weeklyRun, title: "Weekly mail roundup",
            body: "Three threads from example.com need an answer this week: the acme invoice, the venue and the "
                + "contract renewal.",
            createdAt: at(minutesAgo: 2 * 1440), readAt: at(minutesAgo: 2 * 1440 - 30),
            writtenAt: at(minutesAgo: 2 * 1440), changedAt: at(minutesAgo: 2 * 1440))
        for (text, minutes) in [("Release acme 2.0 checklist", 70), ("Finance on the acme refund", 130)] {
            let track = try TestDatabase.insertTrack(db, text: text, hasUpdates: true)
            try db.execute(sql: "UPDATE tracks SET updated_at = ? WHERE id = ?",
                           arguments: [at(minutesAgo: minutes), track])
        }
        try TestDatabase.insertIdea(db, title: "Move the release checklist into the repo",
                                    updatedAt: at(minutesAgo: 180))
    }

    /// Slack today's state: 160 messages in 7 conversations, two with news.
    private static var slackTodayState: String {
        let today = day(daysAgo: 0)
        func line(_ label: String, _ text: String, _ time: String) -> String {
            #"{"label":"\#(label)","text":"\#(text)","at":"\#(today)T\#(time):00Z","link":"https://acme.slack.com/archives/C1/p1"}"#
        }
        return #"{"today":{"v":1,"day":"\#(today)","messages":160,"missed_yesterday":0,"channels":{"#
            + #""C1":{"name":"acme-release","n":24,"lines":["#
            + line("asks_you", "Colleague A asks whether Thursday works for your side.", "09:20") + ","
            + line("decided", "The tag goes out Thursday, after QA signs off.", "09:10") + "]},"
            + #""C2":{"name":"acme-infra","n":31,"lines":["#
            + line("needs_someone", "Colleague D is looking for a reviewer for the DB migration.", "09:30") + "]},"
            + #""C3":{"name":"acme-random","n":60},"C4":{"name":"acme-music","n":20},"#
            + #""D1":{"name":"@Colleague B","n":12},"C5":{"name":"acme-bots","n":9},"C6":{"name":"acme-team-01","n":4}"#
            + #"},"quiet_rest":{"channels":0,"messages":0},"more_rest":{"channels":0,"lines":0}}}"#
    }

    /// The card the recipe draws from that state.
    private static let slackTodayBlocks: String = {
        func row(_ title: String, _ text: String, _ tone: String) -> String {
            #"{"title":"\#(title)","badge":{"text":"\#(text)","tone":"\#(tone)"},"link":"https://acme.slack.com/archives/C1/p1"}"#
        }
        return ##"{"v":1,"blocks":[{"type":"list","title":"#acme-release","rows":["##
            + row("Colleague A asks whether Thursday works for your side.", "asks you", "warning") + ","
            + row("The tag goes out Thursday, after QA signs off.", "decided", "success") + "]},"
            + ##"{"type":"list","title":"#acme-infra","rows":["##
            + row("Colleague D is looking for a reviewer for the DB migration.", "needs someone", "info") + "]}]}"
    }()

    /// Three Slack messages (one row each) and three tracks to create (one
    /// group row with **Approve All 3…**).
    private static func seedApprovals(_ db: Database) throws {
        let messages = [("#acme-release", "Release 2.0 is tagged; the checklist is in the thread."),
                        ("#acme-finance", "The refund is approved on our side."),
                        ("@colleague-a", "I will review the checklist by 15:00.")]
        for (index, (label, text)) in messages.enumerated() {
            _ = try TestDatabase.insertAgentAction(
                db, tool: "send_slack_message", external: true,
                argsJSON: #"{"text":"\#(text)","target":{"account_id":1,"workspace":"acme","channel_id":"C1","#
                    + #""label":"\#(label)"}}"#,
                reason: "Reply in \(label)", turnID: "turn-message-\(index)", createdAt: at(minutesAgo: 30 + index))
        }
        for (index, topic) in ["acme refund", "acme 2.0 rollout", "acme offsite venue"].enumerated() {
            _ = try TestDatabase.insertAgentAction(
                db, tool: "create_track", argsJSON: #"{"text":"Follow \#(topic)"}"#,
                reason: "From your :eyes: reaction on \(topic)", turnID: "turn-track-\(index)",
                createdAt: at(minutesAgo: 60 + index))
        }
    }

    /// One artifact changed today and one from two days ago, routed to `folder`.
    private static func seedOwnerFolder(_ db: Database, folder: Int64) throws {
        let blockers = try TestDatabase.insertAutomation(db, slug: "release-blockers", name: "Release blockers")
        let blockersRun = try TestDatabase.insertAutomationRun(db, automationID: blockers)
        let today = try TestDatabase.insertAutomationOutput(
            db, automationID: blockers, runID: blockersRun, title: "Release blockers",
            body: "Two blockers left: the checklist link and the rollback plan.",
            createdAt: at(minutesAgo: 15), writtenAt: at(minutesAgo: 15), changedAt: at(minutesAgo: 15))
        let digest = try TestDatabase.insertAutomation(db, slug: "release-digest", name: "Release channel digest")
        let digestRun = try TestDatabase.insertAutomationRun(db, automationID: digest)
        let older = try TestDatabase.insertAutomationOutput(
            db, automationID: digest, runID: digestRun, title: "Release channel digest",
            body: "The channel agreed on a staged rollout for acme 2.0.",
            createdAt: at(minutesAgo: 2 * 1440 + 60), readAt: at(minutesAgo: 2 * 1440),
            writtenAt: at(minutesAgo: 2 * 1440 + 60), changedAt: at(minutesAgo: 2 * 1440 + 60))
        try db.execute(sql: "UPDATE automation_outputs SET folder_id = ? WHERE id IN (?, ?)",
                       arguments: [folder, today, older])
    }

    private static func builtin(_ db: Database, id: String, name: String) throws -> Int64 {
        let automation = try TestDatabase.insertAutomation(db, slug: id, name: name)
        try db.execute(sql: "UPDATE automations SET origin = 'builtin', builtin_id = ?, path = ? WHERE id = ?",
                       arguments: [id, "builtin:\(id)", automation])
        return automation
    }

    @discardableResult
    private static func folder(
        _ db: Database, kind: String, parent: Int64?, slug: String, title: String, icon: String = ""
    ) throws -> Int64 {
        try db.execute(sql: """
            INSERT INTO inbox_folders (kind, parent_id, slug, title, icon, position) VALUES (?, ?, ?, ?, ?, 0)
            """, arguments: [kind, parent, slug, title, icon])
        return db.lastInsertedRowID
    }
}

/// A step that ran to its end.
@MainActor
private final class Finished {
    var value = false
}

private extension InboxBulkPressModel.State {
    var isConfirming: Bool {
        if case .confirming = self { return true }
        return false
    }
}
