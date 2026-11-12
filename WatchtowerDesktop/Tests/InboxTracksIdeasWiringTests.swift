import GRDB
import SwiftUI
import ViewInspector
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// Track my threads and Idea finder through `ActionStripActionsView` (inbox
/// redesign phase 3): their root entries draw the news pane and the idea
/// batch pane, an opened thread sits under its back bar, and the Backlog's
/// header offers **Clear Old Ideas…** only while old ideas wait.
@MainActor
final class InboxTracksIdeasWiringTests: XCTestCase {
    private var manager: DatabaseManager!
    private var path = ""
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        (manager, path) = try TestDatabase.createDatabaseManager()
        suite = "InboxTracksIdeasWiringTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        manager = nil
        TestDatabase.cleanup(path: path)
    }

    nonisolated private static func stamp(daysAgo days: Double) -> String {
        AutomationDates.format(Date().addingTimeInterval(-days * 24 * 3600))
    }

    /// The root and Needs approval, the rows migration 00183 seeds.
    nonisolated private static func seedFolders(_ db: Database) throws {
        try db.execute(sql: "INSERT INTO inbox_folders (kind, parent_id, slug, title, position) "
            + "VALUES ('root', NULL, 'inbox', 'Inbox', 0)")
        let root = db.lastInsertedRowID
        try db.execute(sql: "INSERT INTO inbox_folders (kind, parent_id, slug, title, position) "
            + "VALUES ('approvals', ?, 'needs-approval', 'Needs approval', 0)", arguments: [root])
        try db.execute(sql: "INSERT INTO inbox_folder_state (id, revision) VALUES (1, 1)")
    }

    /// A never-read track whose last event was an hour ago: news.
    private func seedNewsTrack() throws -> Int {
        try manager.dbPool.write { db in
            try Self.seedFolders(db)
            let id = try TestDatabase.insertTrack(db, text: "Release acme 2.0 checklist")
            try db.execute(sql: "UPDATE tracks SET updated_at = ?, created_at = ? WHERE id = ?",
                           arguments: [Self.stamp(daysAgo: 0.04), Self.stamp(daysAgo: 0.04), id])
            return Int(id)
        }
    }

    /// Ideas awaiting a verdict, created the given days ago.
    private func seedIdeas(daysAgo: [Double]) throws {
        try manager.dbPool.write { db in
            try Self.seedFolders(db)
            for (n, days) in daysAgo.enumerated() {
                _ = try TestDatabase.insertIdea(db, title: "Idea \(n) for acme",
                                                createdAt: Self.stamp(daysAgo: days),
                                                updatedAt: Self.stamp(daysAgo: days))
            }
        }
    }

    private func makeVM() async -> ActionStripViewModel {
        let vm = ActionStripViewModel(dbPool: manager.dbPool, cliRunner: FakeCLIRunner(), defaults: defaults,
                                      findCLI: { nil }, dayChangeSignals: [])
        await vm.refresh()
        return vm
    }

    private func view(_ vm: ActionStripViewModel) -> ActionStripActionsView {
        var view = ActionStripActionsView(
            vm: vm, cheatSheetRows: [], feature: .off, isEnabling: false, featureError: nil,
            onEnable: {}, onOpenSettings: {}, onOpen: { _ in })
        view.ideas = IdeasViewModel(dbManager: manager)
        view.tracks = TracksViewModel(dbManager: manager)
        view.trackControls = RecordingCustomTrackControls()
        return view
    }

    // MARK: - Track my threads

    func testTracksEntryDrawsNewsPane() async throws {
        let trackID = try seedNewsTrack()
        let vm = await makeVM()
        await vm.selectEntry(InboxFolderEntry.legacyTracks.id)

        let sut = try view(vm).environment(AppState.isolated()).inspect()
        let news = try sut.find(InboxTracksNewsPane.self)
        XCTAssertNoThrow(try news.find(viewWithAccessibilityIdentifier: "inbox.tracksNews.row.\(trackID)"))
        XCTAssertThrowsError(try sut.find(InboxTrackBackBar.self), "the list, no thread open")

        try news.find(button: "All Threads").tap()
        XCTAssertEqual(vm.legacyList, .tracks, "All Threads opens the whole list")
    }

    func testOpenedThreadDrawsBackBarAndTrackPane() async throws {
        let trackID = try seedNewsTrack()
        let vm = await makeVM()
        await vm.selectEntry(InboxFolderEntry.legacyTracks.id)
        vm.openNewsTrack(trackID)

        let sut = try view(vm).environment(AppState.isolated()).inspect()
        XCTAssertThrowsError(try sut.find(InboxTracksNewsPane.self), "the thread replaces the list")
        let pane = try sut.find(InboxTrackPane.self)
        XCTAssertEqual(try pane.actualView().card.track.id, trackID)

        try sut.find(InboxTrackBackBar.self).find(button: "Track my threads").tap()
        XCTAssertNil(vm.openedNewsTrack, "back returns to the news list")
    }

    func testDoneOnOpenedThreadMarksItReadAndGoesBack() async throws {
        let trackID = try seedNewsTrack()
        let vm = await makeVM()
        await vm.selectEntry(InboxFolderEntry.legacyTracks.id)
        vm.openNewsTrack(trackID)

        try view(vm).environment(AppState.isolated()).inspect().find(InboxTrackPane.self).find(button: "Done").tap()
        let deadline = Date().addingTimeInterval(5)
        while vm.openedNewsTrack != nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertNil(vm.openedNewsTrack, "Done goes back to the news list")
        let readAt = try await manager.dbPool.read { db in
            try String.fetchOne(db, sql: "SELECT read_at FROM tracks WHERE id = ?", arguments: [trackID])
        }
        XCTAssertNotNil(readAt)
    }

    func testStopWatchingOnOpenedThreadStopsItAndGoesBack() async throws {
        let trackID = try seedNewsTrack()
        let vm = await makeVM()
        await vm.selectEntry(InboxFolderEntry.legacyTracks.id)
        vm.openNewsTrack(trackID)

        try view(vm).environment(AppState.isolated()).inspect().find(InboxTrackPane.self)
            .find(button: "Stop watching").tap()
        let deadline = Date().addingTimeInterval(5)
        while vm.openedNewsTrackID != nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertNil(vm.openedNewsTrackID, "Stop watching goes back to the news list")
        let dismissedAt = try await manager.dbPool.read { db in
            try String.fetchOne(db, sql: "SELECT dismissed_at FROM tracks WHERE id = ?", arguments: [trackID])
        }
        XCTAssertNotEqual(dismissedAt ?? "", "")
    }

    // MARK: - Idea finder

    func testIdeasEntryDrawsBatchPane() async throws {
        try seedIdeas(daysAgo: [1, 2])
        let vm = await makeVM()
        await vm.selectEntry(InboxFolderEntry.legacyIdeas.id)

        let sut = try view(vm).environment(AppState.isolated()).inspect()
        let batch = try sut.find(IdeaBatchPane.self)
        XCTAssertEqual(try batch.actualView().state, vm.ideaBatch)
        XCTAssertNoThrow(try batch.find(text: "Keep"))

        try batch.find(button: "Backlog · \(vm.ideaBatch.backlogCount)").tap()
        XCTAssertEqual(vm.legacyList, .ideas, "Backlog opens the whole list")
    }

    func testBacklogHeaderShowsClearOldIdeasOnlyWithOldIdeas() async throws {
        try seedIdeas(daysAgo: [1, 45])
        let vm = await makeVM()
        XCTAssertEqual(vm.ideaBatch.olderCount, 1)
        vm.openLegacy(.ideas)
        XCTAssertNoThrow(try view(vm).environment(AppState.isolated()).inspect().find(button: "Clear Old Ideas…"))

        // Only fresh ideas: no button.
        try await manager.dbPool.write { db in
            try db.execute(sql: "UPDATE ideas SET created_at = ?", arguments: [Self.stamp(daysAgo: 1)])
        }
        await vm.refresh()
        XCTAssertEqual(vm.ideaBatch.olderCount, 0)
        XCTAssertThrowsError(try view(vm).environment(AppState.isolated()).inspect().find(button: "Clear Old Ideas…"))
    }

    func testClearOldIdeasConfirmTitle() {
        XCTAssertEqual(ActionStripActionsView.clearOldIdeasTitle(1), "Clear 1 Old Idea")
        XCTAssertEqual(ActionStripActionsView.clearOldIdeasTitle(4), "Clear 4 Old Ideas")
    }
}
