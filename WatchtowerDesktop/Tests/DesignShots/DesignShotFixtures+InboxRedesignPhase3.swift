import GRDB
import SwiftUI
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The Inbox redesign, phase 3 (Track my threads and Idea finder, #1076),
/// drawn from the wired `ActionStripActionsView` over a seeded test database
/// (the `InboxRedesignShotFixtures` pattern): the threads with news and the
/// quiet note, a thread opened under its back bar, today's idea batch part
/// judged and done, and the Backlog with **Clear Old Ideas…**. Every state
/// is reached through the view model's public API. Sample data only, at one
/// fixed moment.
@MainActor
enum InboxRedesignPhase3ShotFixtures {
    private static var paths: [String] = []
    private static var managers: [DatabaseManager] = []
    private static let defaultsSuite = "InboxRedesignPhase3ShotFixtures"
    nonisolated static let now = AutomationDates.parse("2026-11-06T12:00:00Z") ?? Date()

    static func cleanUp() {
        managers = []
        paths.forEach(TestDatabase.cleanup(path:))
        paths = []
        UserDefaults().removePersistentDomain(forName: defaultsSuite)
    }

    nonisolated private static func at(minutesAgo: Double) -> String {
        AutomationDates.format(now.addingTimeInterval(-60 * minutesAgo))
    }

    nonisolated private static func at(daysAgo: Double) -> String {
        at(minutesAgo: daysAgo * 1440)
    }

    /// What one shot opens.
    enum Scene {
        case threads, threadDetail, ideas, ideasDone, ideasBacklog
    }

    static var shots: [DesignShot] {
        let scenes: [(String, Scene)] = [
            ("inbox-r-threads", .threads),
            ("inbox-r-threads-detail", .threadDetail),
            ("inbox-r-ideas", .ideas),
            ("inbox-r-ideas-done", .ideasDone),
            ("inbox-r-ideas-backlog", .ideasBacklog)
        ]
        return scenes.map { name, scene in
            DesignShot(name: name, size: NSSize(width: 1280, height: 760)) { view(scene) }
        }
    }

    // MARK: - The Inbox

    /// The Inbox over a fresh seed, opened at `scene`.
    static func view(_ scene: Scene) -> AnyView {
        do {
            let (manager, path) = try TestDatabase.createDatabaseManager()
            managers.append(manager)
            paths.append(path)
            let seeded = try manager.dbPool.write { db in try seed(db) }
            let defaults = UserDefaults(suiteName: defaultsSuite) ?? .standard
            defaults.removePersistentDomain(forName: defaultsSuite)
            let clock = now
            let vm = ActionStripViewModel(dbPool: manager.dbPool, cliRunner: FakeCLIRunner(), defaults: defaults,
                                          clock: { clock }, findCLI: { nil }, dayChangeSignals: [])
            try open(scene, vm: vm, manager: manager, seeded: seeded)
            let appState = AppState()
            appState.databaseManager = manager
            var inbox = ActionStripActionsView(
                vm: vm, cheatSheetRows: [], feature: .on(lastCheck: nil), isEnabling: false, featureError: nil,
                onEnable: {}, onOpenSettings: {}, onOpen: { _ in },
                ideas: IdeasViewModel(dbManager: manager),
                onRetryBuiltin: { _ in },
                tracks: TracksViewModel(dbManager: manager),
                trackControls: RecordingCustomTrackControls(),
                now: now
            )
            inbox.ideaFacts = { id in
                try? await manager.dbPool.read { db in try IdeaBatchCardFacts.read(db, ideaID: id) }
            }
            return AnyView(inbox
                .environment(appState)
                .environment(\.markdownNavScreens, ["home"])
                .detailBackground())
        } catch {
            return DesignShotFixtures.failure(error)
        }
    }

    /// Drives `vm` to `scene` through its public API; each step runs to its
    /// end and one more read follows, so light and dark draw the same state.
    private static func open(
        _ scene: Scene, vm: ActionStripViewModel, manager: DatabaseManager, seeded: Seeded
    ) throws {
        switch scene {
        case .threads:
            run("Track my threads", vm) { await vm.selectEntry(InboxFolderEntry.legacyTracks.id) }
            XCTAssertEqual(vm.trackSummary.news.count, 6)
            XCTAssertEqual(vm.trackSummary.quietCount, 2)
        case .threadDetail:
            run("the opened thread", vm) {
                await vm.selectEntry(InboxFolderEntry.legacyTracks.id)
                vm.openNewsTrack(seeded.checklistTrack)
            }
            XCTAssertNotNil(vm.openedNewsTrack)
        case .ideas, .ideasDone:
            // The batch is picked by the first read; then the owner's verdicts.
            run("today's batch", vm) { await vm.selectEntry(InboxFolderEntry.legacyIdeas.id) }
            let batch = vm.ideaBatch.batchIDs
            XCTAssertEqual(batch.count, 13)
            let judged = scene == .ideas ? 3 : batch.count
            try manager.dbPool.write { db in try judge(db, Array(batch.prefix(judged))) }
            run("the judged batch", vm) {}
            XCTAssertEqual(vm.ideaBatch.judgedCount, judged)
        case .ideasBacklog:
            run("the Backlog", vm) { vm.openLegacy(.ideas) }
            XCTAssertEqual(vm.legacyList, .ideas)
            XCTAssertGreaterThan(vm.ideaBatch.olderCount, 0)
        }
    }

    /// Every third idea dropped, the rest kept, all today.
    nonisolated private static func judge(_ db: Database, _ ids: [Int]) throws {
        for (index, id) in ids.enumerated() {
            try db.execute(sql: "UPDATE ideas SET status = ?, updated_at = ? WHERE id = ?",
                           arguments: [index % 3 == 2 ? "rejected" : "active", at(minutesAgo: Double(30 + index)), id])
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

    // MARK: - The database

    struct Seeded {
        let checklistTrack: Int
    }

    /// The tree (root, Needs approval); six threads with news and two quiet
    /// for over 30 days; 30 ideas from the last 30 days and four older.
    nonisolated private static func seed(_ db: Database) throws -> Seeded {
        try db.execute(sql: "INSERT INTO inbox_folders (kind, parent_id, slug, title, position) "
            + "VALUES ('root', NULL, 'inbox', 'Inbox', 0)")
        let root = db.lastInsertedRowID
        try db.execute(sql: "INSERT INTO inbox_folders (kind, parent_id, slug, title, position) "
            + "VALUES ('approvals', ?, 'needs-approval', 'Needs approval', 0)", arguments: [root])
        try db.execute(sql: "INSERT INTO inbox_folder_state (id, revision) VALUES (1, 1)")
        _ = try TestDatabase.insertSlackAccount(db, currentUserID: "1:U001")
        try TestDatabase.insertChannel(db, id: "C001", name: "acme-release")
        try TestDatabase.insertUser(db, id: "U002", name: "colleague-a", displayName: "Colleague A")
        let checklist = try seedTracks(db)
        try seedIdeas(db)
        return Seeded(checklistTrack: checklist)
    }

    /// One news thread per chip, two without a chip, two quiet ones.
    nonisolated private static func seedTracks(_ db: Database) throws -> Int {
        let checklist = try track(
            db, "Release acme 2.0 checklist", minutesAgo: 20, ballOn: "1:U001",
            events: ["Colleague A fixed the checklist link and asks you to sign off.", "The rollback plan is attached."])
        _ = try track(db, "Pricing page for acme Pro", minutesAgo: 75, category: "decision",
                      events: ["The team settled on two tiers; the annual discount stays at 15 %."])
        let mention = #"[{"ts":"1762420000.000100","channel_id":"C001","author":"Colleague B","#
            + #""text":"<@U001> can you look at the staging migration before Friday?"}]"#
        _ = try track(db, "Staging database migration", minutesAgo: 140, sourceRefs: mention, events: [])
        _ = try track(db, "Finance on the acme refund", minutesAgo: 300, hasUpdates: true,
                      events: ["Finance approved the refund; the transfer goes out on Monday.", "", ""])
        _ = try track(db, "Offsite venue at example.com", minutesAgo: 600,
                      events: ["The venue sent a new quote with the dinner included."])
        _ = try track(db, "Mobile release notes", minutesAgo: 1500, events: [],
                      context: "Colleague C drafts the notes for the store listing.")
        for (text, days) in [("Hiring loop for the platform team", 41.0), ("Q3 vendor review", 56.0)] {
            let id = try track(db, text, minutesAgo: days * 1440, events: [])
            try db.execute(sql: "UPDATE tracks SET read_at = ? WHERE id = ?", arguments: [at(daysAgo: days - 1), id])
        }
        return checklist
    }

    /// A track last moved `minutesAgo`, with `events` (unread, the first newest).
    nonisolated private static func track(
        _ db: Database,
        _ text: String,
        minutesAgo: Double,
        ballOn: String = "",
        category: String = "task",
        sourceRefs: String = "[]",
        hasUpdates: Bool = false,
        events: [String],
        context: String = "Discussed in #acme-release"
    ) throws -> Int {
        let id = try TestDatabase.insertTrack(db, text: text, context: context, category: category,
                                              sourceRefs: sourceRefs, hasUpdates: hasUpdates,
                                              assigneeUserID: "1:U001")
        try db.execute(sql: "UPDATE tracks SET ball_on = ?, updated_at = ?, created_at = ? WHERE id = ?",
                       arguments: [ballOn, at(minutesAgo: minutesAgo), at(daysAgo: 20), id])
        for (index, summary) in events.enumerated() {
            try db.execute(sql: "INSERT INTO track_events (track_id, summary, created_at) VALUES (?, ?, ?)",
                           arguments: [id, summary.isEmpty ? "An earlier update" : summary,
                                       at(minutesAgo: minutesAgo + Double(index * 30))])
        }
        return Int(id)
    }

    /// 30 ideas from the last 30 days (oldest first is the batch order) and
    /// four older than 30 days; the card shown after three verdicts carries two quotes.
    nonisolated private static func seedIdeas(_ db: Database) throws {
        let titles = [
            "Move the release checklist into the repo", "One onboarding page for every acme team",
            "A shared glossary for the billing terms", "Weekly digest of the support queue",
            "Template for the rollback plan", "Automate the staging refresh"
        ]
        for index in 0..<30 {
            let created = at(daysAgo: 28 - Double(index) * 0.9)
            let title = index < titles.count ? titles[index] : "Idea \(index + 1) from #acme-release"
            let id = try TestDatabase.insertIdea(
                db, title: title,
                essence: index == 3 ? "Support questions repeat week to week; a Monday digest of the queue "
                    + "shows the team what to fix first." : "",
                createdAt: created, updatedAt: created)
            if index == 3 {
                _ = try TestDatabase.insertIdeaMention(
                    db, ideaID: id, quote: "Third week in a row the same export question tops the queue.",
                    author: "Colleague A", saidAt: at(daysAgo: 25))
                _ = try TestDatabase.insertIdeaMention(
                    db, ideaID: id, quote: "A short Monday summary would save us the triage call.",
                    author: "Colleague B", saidAt: at(daysAgo: 24))
            }
        }
        for days in [35.0, 44, 60, 90] {
            _ = try TestDatabase.insertIdea(db, title: "An old idea from \(Int(days)) days ago",
                                            createdAt: at(daysAgo: days), updatedAt: at(daysAgo: days))
        }
    }
}

/// A step that ran to its end.
@MainActor
private final class Finished {
    var value = false
}
