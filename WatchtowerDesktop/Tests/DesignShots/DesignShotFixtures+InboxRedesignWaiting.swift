import GRDB
import SwiftUI
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The Inbox redesign, phase 2 (Waiting for me and Mail waiting, #1076),
/// drawn from the wired views over a seeded test database at one fixed
/// moment (the `InboxRedesignShotFixtures` pattern): Waiting for me by
/// section with the folded Older and its note row, one row hot, the list
/// with both entries in Needs you, Mail waiting by sender, the Mute Senders
/// panel, a sender's Mark All Done… asking with its count (pointer on no
/// row: the asking press keeps its buttons shown) and the line of a press
/// that stopped part-way. The two artifacts carry the blocks their
/// built-in recipes write, built from the seeded rows. Sample data only.
///
/// A shot gives no keyboard focus and no pointer, so the hot row is the
/// keyboard's (`InboxArtifactCard.focusedRef`, the card the reading pane
/// draws, with the Inbox's own row hooks): the hover and the focus show
/// the same overlay. A popover does not render in a shot: the Mute
/// Senders panel stands where it opens, under its button.
@MainActor
enum InboxRedesignWaitingShotFixtures {
    private static var paths: [String] = []
    private static var managers: [DatabaseManager] = []
    private static let defaultsSuite = "InboxRedesignWaitingShotFixtures"
    nonisolated static let now = AutomationDates.parse("2026-11-11T12:00:00Z") ?? Date()

    static func cleanUp() {
        managers = []
        paths.forEach(TestDatabase.cleanup(path:))
        paths = []
        UserDefaults().removePersistentDomain(forName: defaultsSuite)
    }

    private static let owner = Owner(
        id: "1:U001", source: .slack, slackUserID: "1:U001", email: "", jiraAccountID: "", displayName: "Me"
    )
    private static let navScreens: Set<String> = ["home"]
    /// The busiest sender: its Mark All Done… asks to close 46.
    static let busiestSender = "notifications@example.com"
    /// The error the partial Mark All Done… stopped on.
    static let partialError = "The database was busy, nothing else was changed."

    private static var today: String { HomeFeedBuilder.dayString(now, calendar: .current) }

    private static func at(minutesAgo: Int) -> String {
        AutomationDates.format(now.addingTimeInterval(TimeInterval(-60 * minutesAgo)))
    }

    /// What one shot opens.
    enum Scene {
        case waitingPeople, waitingHover, listMailRow, mailWaiting, mutePanel, bulkConfirm, bulkPartial
    }

    static var shots: [DesignShot] {
        let inbox: [(String, CGFloat, Scene)] = [
            ("inbox-r-waiting-people", 760, .waitingPeople),
            ("inbox-r-list-mail-row", 640, .listMailRow),
            ("inbox-r-mail-waiting", 760, .mailWaiting),
            ("inbox-r-mail-mute-panel", 760, .mutePanel),
            // The pointer is on no row: the asking press keeps its buttons shown.
            ("inbox-r-mail-bulk-confirm", 760, .bulkConfirm),
            ("inbox-r-mail-bulk-partial", 760, .bulkPartial)
        ]
        return inbox.map { name, height, scene in
            DesignShot(name: name, size: NSSize(width: 1280, height: height)) { view(scene) }
        } + [
            // The reading pane at its narrow width: the hot row's actions
            // over its trailing edge, cut at the line, never past the row.
            DesignShot(name: "inbox-r-waiting-hover", size: NSSize(width: 460, height: 620)) {
                pane(.waitingHover)
            }
        ]
    }

    // MARK: - The Inbox

    /// The three-column Inbox over a fresh seed, opened at `scene`.
    static func view(_ scene: Scene) -> AnyView {
        do {
            let (vm, seeded, manager) = try model()
            open(scene, vm: vm, seeded: seeded)
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
                if scene == .mutePanel {
                    inbox.overlay(alignment: .topTrailing) { muteStandIn(vm) }
                } else {
                    inbox
                }
            }
            .environment(appState)
            .environment(\.markdownNavScreens, navScreens)
            .detailBackground())
        } catch {
            return DesignShotFixtures.failure(error)
        }
    }

    /// The reading pane's column over Waiting for me as the pane draws it —
    /// the pane header, then the card with the Inbox's row hooks — with one
    /// row hot.
    static func pane(_ scene: Scene) -> AnyView {
        do {
            let (vm, seeded, _) = try model()
            open(scene, vm: vm, seeded: seeded)
            guard let card = vm.feed.outputs.first(where: { $0.id == seeded.waitingOutput }),
                  case let .artifact(result, cardActions) = InboxCardLayout.of(card) else {
                XCTFail("the Waiting for me card is not in the feed")
                return AnyView(Text("no card").foregroundStyle(.red))
            }
            let hot = ArtifactRef(kind: .inboxItem, id: seeded.hotItem)
            let header = InboxArtifactPaneHeader(
                content: InboxFolderEntries.content(.artifact(card), vm.entryInputs),
                subtitle: InboxWaitingTexts.peoplePaneSubtitle(vm.folderMenu.snapshot.peopleWaiting),
                menu: nil) {}
            let artifact = InboxArtifactCard(
                card: card, result: result, cardActions: cardActions, people: vm.feed.artifactPeople,
                navScreens: navScreens, isWriting: false, onCommand: { _ in }, onDone: {}, onDismiss: {},
                workbenches: [], targets: vm.targetButtons(now: now),
                refHooks: InboxRefHooks(vm: vm, navScreens: navScreens).hooks, focusedRef: hot)
            return AnyView(InboxCardColumn {
                VStack(alignment: .leading, spacing: Spacing.page) {
                    header
                    artifact
                }
            }
            .environment(\.markdownNavScreens, navScreens)
            .detailBackground())
        } catch {
            return DesignShotFixtures.failure(error)
        }
    }

    /// A fresh seed and the strip's view model over it, read once.
    private static func model() throws -> (ActionStripViewModel, Seeded, DatabaseManager) {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        managers.append(manager)
        paths.append(path)
        let seeded = try manager.dbPool.write { db in try seed(db) }
        let defaults = UserDefaults(suiteName: defaultsSuite) ?? .standard
        defaults.removePersistentDomain(forName: defaultsSuite)
        let clock = now
        // Labeled: a trailing closure would bind to `automationsWake`.
        // swiftlint:disable trailing_closure
        let vm = ActionStripViewModel(dbPool: manager.dbPool, cliRunner: FakeCLIRunner(), defaults: defaults,
                                      clock: { clock })
        // swiftlint:enable trailing_closure
        return (vm, seeded, manager)
    }

    /// Drives `vm` to `scene` through its public API, each step to its end
    /// and one more read after it, so light and dark draw the same state.
    private static func open(_ scene: Scene, vm: ActionStripViewModel, seeded: Seeded) {
        switch scene {
        case .listMailRow:
            run("today's brief", vm) { await vm.selectEntry("day:\(today)") }
            XCTAssertEqual(vm.folderList.sections.first?.title, "Needs you")
        case .waitingPeople, .waitingHover:
            run("Waiting for me", vm) { await vm.selectEntry("artifact:\(seeded.waitingOutput)") }
            XCTAssertEqual(vm.entrySelection, "artifact:\(seeded.waitingOutput)")
            XCTAssertEqual(vm.folderMenu.snapshot.peopleWaiting.older, 4)
        case .mailWaiting, .mutePanel, .bulkConfirm, .bulkPartial:
            run("Mail waiting", vm) { await vm.selectEntry("artifact:\(seeded.mailOutput)") }
            XCTAssertEqual(vm.entrySelection, "artifact:\(seeded.mailOutput)")
            XCTAssertTrue(vm.folderMenu.snapshot.refState.isShown(InboxRef(kind: .mailSender, key: busiestSender)))
            let press = vm.bulk.model(for: .sender(busiestSender))
            if scene == .bulkConfirm { plan(press, ids: seeded.busiestIDs) }
            if scene == .bulkPartial {
                plan(press, ids: seeded.busiestIDs)
                let result = InboxBulkResult.partial(done: 12, of: seeded.busiestIDs.count, error: partialError)
                InboxFolderMenuShotFixtures.spin(until: "the partial result", press.state == .finished(result)) {
                    press.confirm { _ in result }
                }
                run("the read after the press", vm) {}
            }
        }
    }

    /// The sender's Mark All Done… pressed: its dry run (a fake closure,
    /// no CLI) names `ids`, and the row asks.
    private static func plan(_ press: InboxBulkPressModel, ids: [String]) {
        let plan = InboxBulkPlan(ids: ids, count: ids.count)
        InboxFolderMenuShotFixtures.spin(until: "the confirmation", press.state == .confirming(plan)) {
            press.begin { plan }
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

    /// The Mute Senders panel where its popover opens, under **Mute
    /// Senders…** in the pane header, as it opens: the senders read
    /// afresh, none ticked.
    private static func muteStandIn(_ vm: ActionStripViewModel) -> some View {
        MuteSendersPopover(load: { try await vm.muteSenderCandidates() }, mute: { _ in }, onApplied: { _ in })
            .popoverSurface()
            // The popover's own material and shadow, which a shot cannot draw.
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.12)))
            // One layer, so the shadow falls behind the panel, not under each label.
            .compositingGroup()
            .shadow(color: FloatingShadow.color, radius: FloatingShadow.radius, y: FloatingShadow.y)
            .padding(.top, 56)
            .padding(.trailing, 50)
    }

    // MARK: - The database

    struct Seeded {
        let waitingOutput: Int64
        let mailOutput: Int64
        /// Today's newest ping: the hot row.
        let hotItem: Int64
        /// The busiest sender's open mail.
        let busiestIDs: [String]
    }

    /// One waiting person item as the seed writes it and Waiting for me lists it.
    private struct Ping {
        let trigger: String
        let channel: String
        let sender: String
        let title: String
        let text: String
        let minutesAgo: Int
    }

    private static let pings: [Ping] = [
        Ping(trigger: "dm", channel: "D001", sender: "U003", title: "Colleague B in a DM",
             text: "Will you approve the acme budget before Friday?", minutesAgo: 40),
        Ping(trigger: "mention", channel: "C001", sender: "U002", title: "Colleague A in #acme-release",
             text: "Can you check the checklist before the tag?", minutesAgo: 130),
        Ping(trigger: "linear_assigned", channel: "ACME-210", sender: "U002", title: "ACME-210 — assigned to you",
             text: "Release checklist v2 — ready for review", minutesAgo: 170),
        Ping(trigger: "thread_reply", channel: "C002", sender: "U004", title: "Colleague C in #acme-infra",
             text: "Who reviews the migration?", minutesAgo: 26 * 60),
        Ping(trigger: "linear_comment_mention", channel: "ACME-188", sender: "U003",
             title: "ACME-188 — mentioned you", text: "@you can we drop the old export?", minutesAgo: 51 * 60),
        Ping(trigger: "mention", channel: "C001", sender: "U004", title: "Colleague C in #acme-release",
             text: "Is the rollback plan written down?", minutesAgo: 4 * 1440),
        Ping(trigger: "mention", channel: "C002", sender: "U002", title: "Colleague A in #acme-infra",
             text: "Can you share the staging credentials process?", minutesAgo: 9 * 1440),
        Ping(trigger: "dm", channel: "D001", sender: "U003", title: "Colleague B in a DM",
             text: "Did you see the offsite venue options?", minutesAgo: 12 * 1440),
        Ping(trigger: "linear_assigned", channel: "ACME-97", sender: "U004", title: "ACME-97 — assigned to you",
             text: "Flaky export test on main", minutesAgo: 15 * 1440),
        Ping(trigger: "thread_reply", channel: "C001", sender: "U002", title: "Colleague A in #acme-release",
             text: "Any news on the 1.9 hotfix?", minutesAgo: 21 * 1440)
    ]

    /// Mail waiting's senders (address, open, of them today) and the
    /// subject of their mail.
    private static let senders: [(String, Int, Int, String)] = [
        (busiestSender, 46, 3, "Your weekly acme digest"),
        ("jira@example.com", 21, 2, "[ACME-210] Release checklist v2 updated"),
        ("calendar@example.com", 12, 1, "Invitation: acme release sync"),
        ("builds@acme.example.com", 9, 0, "Build #1042 failed on main"),
        ("billing@example.com", 8, 1, "Your invoice for November"),
        ("newsletter@example.com", 7, 0, "This week at example.com"),
        ("colleague-h@example.com", 6, 2, "Re: the acme offsite agenda"),
        ("alerts@acme.example.com", 5, 0, "Disk usage above 80% on acme-db"),
        ("vendor@example.com", 3, 1, "Contract renewal for 2027"),
        ("qa@example.com", 3, 0, "Test run report: acme 2.0"),
        ("hr@example.com", 2, 0, "Open enrolment closes soon"),
        ("events@example.com", 2, 1, "Your ticket for the summit"),
        ("security@example.com", 2, 0, "New sign-in to your account"),
        ("docs@example.com", 1, 0, "A page you follow was edited"),
        ("survey@example.com", 1, 0, "Two minutes of your time?")
    ]

    /// The tree (root, Needs approval), today's brief, the people who wait
    /// (three today, three this week, four older), the mail by sender, and
    /// the two built-ins' artifacts as their recipes write them.
    private static func seed(_ db: Database) throws -> Seeded {
        // The migration's seed rows (the test schema is DDL only).
        try db.execute(sql: """
            INSERT INTO inbox_folders (kind, parent_id, slug, title, icon, position)
            VALUES ('root', NULL, 'inbox', 'Inbox', '', 0)
            """)
        let root = db.lastInsertedRowID
        try db.execute(sql: """
            INSERT INTO inbox_folders (kind, parent_id, slug, title, icon, position)
            VALUES ('approvals', ?, 'needs-approval', 'Needs approval', '', 0)
            """, arguments: [root])
        try db.execute(sql: "INSERT INTO inbox_folder_state (id, revision) VALUES (1, 1)")
        _ = try TestDatabase.insertSlackAccount(db, currentUserID: "1:U001")
        try TestDatabase.insertChannel(db, id: "C001", name: "acme-release")
        try TestDatabase.insertChannel(db, id: "C002", name: "acme-infra")
        for (id, name) in [("U002", "Colleague A"), ("U003", "Colleague B"), ("U004", "Colleague C")] {
            try TestDatabase.insertUser(db, id: id, name: name.lowercased().replacingOccurrences(of: " ", with: "-"),
                                        displayName: name)
        }
        try TestDatabase.insertBriefing(
            db, userID: "1:U001", date: today, role: "Engineering lead · acme",
            attention: #"[{"text":"Colleague B waits on the acme budget","priority":"high"}]"#)
        try db.execute(sql: "UPDATE briefings SET created_at = ? WHERE date = ?", arguments: [at(minutesAgo: 300), today])

        let (waitingOutput, hotItem) = try seedWaiting(db)
        let (mailOutput, busiestIDs) = try seedMail(db)
        return Seeded(waitingOutput: waitingOutput, mailOutput: mailOutput, hotItem: hotItem, busiestIDs: busiestIDs)
    }

    /// The pings and Waiting for me's artifact: Today, This week and Older
    /// (the note row first, then the older rows), as `waiting-for-me.md`
    /// draws them.
    private static func seedWaiting(_ db: Database) throws -> (Int64, Int64) {
        let startOfToday = InboxToday.sinceUTC(now: now, calendar: .current)
        let olderCutoff = AutomationDates.format(now.addingTimeInterval(-WaitingQueries.olderAfter))
        var sections: [String: [[String: Any]]] = [:]
        var hot: Int64 = 0
        for (index, ping) in pings.enumerated() {
            let stamp = at(minutesAgo: ping.minutesAgo)
            let id = try TestDatabase.insertInboxItem(
                db, channelID: ping.channel, messageTS: "1762800000.0002\(index)", senderUserID: ping.sender,
                triggerType: ping.trigger, snippet: ping.text,
                permalink: "https://acme.slack.com/archives/\(ping.channel)/p17628000000002\(index)")
            try db.execute(sql: "UPDATE inbox_items SET created_at = ? WHERE id = ?", arguments: [stamp, id])
            if index == 0 { hot = id }
            let section = stamp >= startOfToday ? "today" : stamp <= olderCutoff ? "older" : "week"
            var row: [String: Any] = [
                "title": ping.title, "subtitle": ping.text, "badge": ["text": age(ping.minutesAgo)],
                "ref": ["kind": "inbox_item", "id": id]
            ]
            if ping.minutesAgo >= 24 * 60 { row["tone"] = "warning" }
            sections[section, default: []].append(row)
        }
        var lists: [[String: Any]] = []
        for (key, title) in [("today", "Today"), ("week", "This week")] {
            if let rows = sections[key] { lists.append(["type": "list", "title": "\(title) · \(rows.count)", "rows": rows]) }
        }
        if let older = sections["older"] {
            let note: [String: Any] = [
                "title": "\(older.count) items are older than 7 days", "subtitle": "Nobody has followed up on them.",
                "ref": ["kind": "waiting_older", "id": "people"]
            ]
            lists.append(["type": "list", "title": "Older · \(older.count)", "rows": [note] + older])
        }
        let waiting = try builtin(db, id: "waiting-for-me", name: "Waiting for me")
        let output = try TestDatabase.insertAutomationOutput(
            db, automationID: waiting, runID: try TestDatabase.insertAutomationRun(db, automationID: waiting),
            title: "Waiting for me", body: "", createdAt: at(minutesAgo: 6), blocksJSON: try blocks(lists),
            outputKey: "waiting", writtenAt: at(minutesAgo: 6), changedAt: at(minutesAgo: 6))
        return (output, hot)
    }

    /// The mail and Mail waiting's artifact: the share line, then one row per
    /// sender, the busiest first, as `mail-waiting.md` draws them from the
    /// same read the Desktop's own numbers come from.
    private static func seedMail(_ db: Database) throws -> (Int64, [String]) {
        var busiest: [String] = []
        var serial = 0
        for (address, open, todayCount, subject) in senders {
            for index in 0..<open {
                serial += 1
                // Today's mail within the last two hours, the rest spread
                // over the past three weeks.
                let minutes = index < todayCount ? 10 + 25 * index : 1440 + (serial * 331) % (20 * 1440)
                let id = try TestDatabase.insertInboxItem(
                    db, channelID: "mail", messageTS: "m\(serial)", senderUserID: address,
                    triggerType: "email_received", snippet: "\(subject) — sent to you at example.com",
                    permalink: "https://mail.google.com/mail/u/0/#all/18c0\(serial)")
                try db.execute(sql: "UPDATE inbox_items SET created_at = ? WHERE id = ?",
                               arguments: [at(minutesAgo: minutes), id])
                if address == busiestSender { busiest.append(String(id)) }
            }
        }
        let summary = try WaitingQueries.mailSenders(
            db, nowUTC: AutomationDates.format(now), startOfTodayUTC: InboxToday.sinceUTC(now: now, calendar: .current),
            limit: senders.count)
        let rows: [[String: Any]] = summary.senders.map { sender in
            [
                "title": sender.address,
                "subtitle": "\(sender.open) open · \(sender.today) today · \(sender.subject)",
                "badge": ["text": String(sender.open)],
                "link": "https://mail.google.com/mail/u/0/#search/from%3A\(sender.address)",
                "ref": ["kind": "mail_sender", "id": sender.address]
            ]
        }
        let top = min(10, summary.senderCount)
        let out: [[String: Any]] = [
            ["type": "text", "markdown": "\(summary.topTenShare)% of this mail comes from \(top) senders."],
            ["type": "list", "rows": rows, "empty": "No mail is waiting on you"]
        ]
        let mail = try builtin(db, id: "mail-waiting", name: "Mail waiting")
        let output = try TestDatabase.insertAutomationOutput(
            db, automationID: mail, runID: try TestDatabase.insertAutomationRun(db, automationID: mail),
            title: "Mail waiting", body: "", createdAt: at(minutesAgo: 6), blocksJSON: try blocks(out),
            outputKey: "mail", writtenAt: at(minutesAgo: 6), changedAt: at(minutesAgo: 6))
        return (output, busiest)
    }

    /// Go's `ageText`: "< 1 h", "3 h", "26 h", "2 days".
    private static func age(_ minutes: Int) -> String {
        switch minutes {
        case ..<60: "< 1 h"
        case ..<(48 * 60): "\(minutes / 60) h"
        default: "\(minutes / 1440) days"
        }
    }

    private static func blocks(_ list: [[String: Any]]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["v": 1, "blocks": list], options: [.sortedKeys])
        return try XCTUnwrap(String(bytes: data, encoding: .utf8))
    }

    private static func builtin(_ db: Database, id: String, name: String) throws -> Int64 {
        let automation = try TestDatabase.insertAutomation(db, slug: id, name: name)
        try db.execute(sql: "UPDATE automations SET origin = 'builtin', builtin_id = ?, path = ? WHERE id = ?",
                       arguments: [id, "builtin:\(id)", automation])
        return automation
    }
}

/// A step that ran to its end.
@MainActor
private final class Finished {
    var value = false
}
