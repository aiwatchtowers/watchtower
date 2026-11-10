import GRDB
import SwiftUI
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The Inbox drawn from the wired views (plan Task 12): the folder menu, the
/// root's entries and the selected artifact through `ActionStripActionsView`
/// over a test database — Waiting for me pinned first, the legacy entries
/// (today's Morning brief, Track my threads, Idea finder) and an owner
/// automation's artifact. b-01's main panel. Sample data only, at one fixed
/// moment.
@MainActor
enum InboxFoldersShotFixtures {
    private static var paths: [String] = []
    private static let defaultsSuite = "InboxFoldersShotFixtures"
    nonisolated static let now = AutomationDates.parse("2026-11-06T12:00:00Z") ?? Date()

    static func cleanUp() {
        paths.forEach(TestDatabase.cleanup(path:))
        paths = []
        UserDefaults().removePersistentDomain(forName: defaultsSuite)
    }

    private static func at(minutesAgo: Int) -> String {
        AutomationDates.format(now.addingTimeInterval(TimeInterval(-60 * minutesAgo)))
    }

    /// b-01's main panel: the root selected, Weekly mail roundup open.
    static func root() -> AnyView {
        do {
            let (pool, path) = try TestDatabase.createPool()
            paths.append(path)
            let weekly = try pool.write { db in try seed(db) }
            let defaults = UserDefaults(suiteName: defaultsSuite) ?? .standard
            defaults.removePersistentDomain(forName: defaultsSuite)
            let clock = now
            // Labeled: a trailing closure would bind to `automationsWake`.
            // swiftlint:disable:next trailing_closure
            let vm = ActionStripViewModel(dbPool: pool, cliRunner: FakeCLIRunner(), defaults: defaults, clock: { clock })
            InboxFolderMenuShotFixtures.spin(until: "the Inbox read", vm.folderList.rows.count > 1) {
                await vm.refresh()
                await vm.selectEntry("artifact:\(weekly)")
            }
            return AnyView(ActionStripActionsView(
                vm: vm, cheatSheetRows: [], feature: .on(lastCheck: nil), isEnabling: false, featureError: nil,
                onEnable: {}, onOpenSettings: {}, onOpen: { _ in }, now: now
            )
            .environment(AppState())
            .detailBackground())
        } catch {
            return DesignShotFixtures.failure(error)
        }
    }

    /// The tree, Waiting for me with four open pings, today's brief, two
    /// tracks, one idea to judge, three approvals and the weekly roundup.
    private static func seed(_ db: Database) throws -> Int64 {
        // The migration's seed rows (the test schema is DDL only) and the
        // owner's folders; the Desktop itself never writes these tables.
        let root = try folder(db, kind: "root", parent: nil, slug: "inbox", title: "Inbox", position: 0)
        try folder(db, kind: "approvals", parent: root, slug: "needs-approval", title: "Needs approval", position: 0)
        try db.execute(sql: "INSERT INTO inbox_folder_state (id, revision) VALUES (1, 1)")
        let release = try folder(db, parent: root, slug: "release", title: "Release acme 2.0", position: 0, icon: "flag")
        try folder(db, parent: release, slug: "blockers", title: "Blockers", position: 0, icon: "shippingbox")
        try folder(db, parent: root, slug: "team", title: "Team", position: 1, icon: "person.2")
        _ = try TestDatabase.insertSlackAccount(db, currentUserID: "1:U001")

        var pings: [(String, Int64)] = []
        for (index, text) in ["Can you check the checklist?", "Will you approve the budget?",
                              "Who reviews the migration?", "Rollback plan?"].enumerated() {
            pings.append(("inbox_item", try TestDatabase.insertInboxItem(
                db, messageTS: "1700000000.00010\(index)", snippet: text)))
        }
        let waiting = try insertBuiltin(db, id: "waiting-for-me", name: "Waiting for me")
        let waitingRun = try TestDatabase.insertAutomationRun(db, automationID: waiting)
        try TestDatabase.insertAutomationOutput(
            db, automationID: waiting, runID: waitingRun, title: "Waiting for me", body: "",
            createdAt: at(minutesAgo: 6), blocksJSON: listDocument(pings), outputKey: "waiting")

        try TestDatabase.insertBriefing(db, userID: "1:U001", date: HomeFeedBuilder.dayString(now, calendar: .current))
        for (text, minutes) in [("Release acme 2.0 checklist", 60), ("Finance on the acme refund", 70)] {
            let track = try TestDatabase.insertTrack(db, text: text, hasUpdates: true)
            try db.execute(sql: "UPDATE tracks SET updated_at = ? WHERE id = ?",
                           arguments: [at(minutesAgo: minutes), track])
        }
        try TestDatabase.insertIdea(db, title: "Move the release checklist into the repo",
                                    updatedAt: at(minutesAgo: 180))
        for turn in ["turn-1", "turn-2", "turn-3"] {
            _ = try TestDatabase.insertAgentAction(db, turnID: turn, createdAt: at(minutesAgo: 30))
        }

        let roundup = try TestDatabase.insertAutomation(db, slug: "weekly-mail", name: "Weekly mail roundup")
        let run = try TestDatabase.insertAutomationRun(db, automationID: roundup)
        return try TestDatabase.insertAutomationOutput(
            db, automationID: roundup, runID: run, title: "Weekly mail roundup",
            body: "Three threads from example.com need an answer this week: the acme invoice, the venue for the "
                + "offsite and the contract renewal.",
            createdAt: at(minutesAgo: 120))
    }

    @discardableResult
    private static func folder(
        _ db: Database,
        kind: String = "owner",
        parent: Int64?,
        slug: String,
        title: String,
        position: Int,
        icon: String = ""
    ) throws -> Int64 {
        try db.execute(sql: """
            INSERT INTO inbox_folders (kind, parent_id, slug, title, icon, position) VALUES (?, ?, ?, ?, ?, ?)
            """, arguments: [kind, parent, slug, title, icon, position])
        return db.lastInsertedRowID
    }

    /// A v1 block document with one list, a row per ping with its ref.
    private static func listDocument(_ refs: [(String, Int64)]) -> String {
        let rows = refs.map { #"{"title":"row \#($0.1)","ref":{"kind":"\#($0.0)","id":\#($0.1)}}"# }
        return #"{"v":1,"blocks":[{"type":"list","rows":[\#(rows.joined(separator: ","))]}]}"#
    }

    private static func insertBuiltin(_ db: Database, id: String, name: String) throws -> Int64 {
        let automation = try TestDatabase.insertAutomation(db, slug: id, name: name)
        try db.execute(sql: "UPDATE automations SET origin = 'builtin', builtin_id = ?, path = ? WHERE id = ?",
                       arguments: [id, "builtin:\(id)", automation])
        return automation
    }
}
