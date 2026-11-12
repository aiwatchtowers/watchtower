import XCTest
import GRDB
import SwiftUI
import ViewInspector
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The Inbox strip's Actions segment and its reaction cheat sheet: inline on
/// an empty strip (with the feature's enable/status line), behind a `?`
/// popover on a non-empty one, rows always from the live dictionary.
@MainActor
final class ActionStripActionsViewTests: XCTestCase {
    private var paths: [String] = []

    override func tearDown() {
        paths.forEach { TestDatabase.cleanup(path: $0) }
        paths = []
        super.tearDown()
    }

    private func makePool(_ seed: (Database) throws -> Void = { _ in }) throws -> DatabasePool {
        let (pool, path) = try TestDatabase.createPool()
        paths.append(path)
        try pool.write(seed)
        return pool
    }

    private func stripVM(_ pool: DatabasePool) async -> ActionStripViewModel {
        let vm = ActionStripViewModel(dbPool: pool, cliRunner: FakeCLIRunner())
        await vm.refresh()
        return vm
    }

    /// The rows the real `ActionStripView` passes in: the AppState-owned
    /// dictionary VM's `cheatSheetRows` over the same DB.
    private func dictionaryRows(_ pool: DatabasePool) async -> [ReactionCheatSheet.Row] {
        let dictionary = ReactionDictionaryViewModel(dbPool: pool)
        await dictionary.refreshAsync()
        return dictionary.cheatSheetRows
    }

    private func view(
        _ vm: ActionStripViewModel,
        rows: [ReactionCheatSheet.Row],
        feature: ReactionCheatSheetView.FeatureState
    ) -> ActionStripActionsView {
        ActionStripActionsView(
            vm: vm,
            cheatSheetRows: rows,
            feature: feature,
            isEnabling: false,
            featureError: nil,
            onEnable: {},
            onOpenSettings: {},
            onOpen: { _ in }
        )
    }

    func testEmptyStripWithFeatureOffShowsTheCheatSheetAndEnableButton() async throws {
        let pool = try makePool { db in
            try TestDatabase.insertReactionCommandMapping(db, emoji: "pushpin", tool: "brief_context")
        }
        let sut = view(await stripVM(pool), rows: await dictionaryRows(pool), feature: .off)

        XCTAssertNoThrow(try sut.inspect().find(ReactionCheatSheetView.self))
        XCTAssertNoThrow(try sut.inspect().find(button: "Enable Reaction Commands"))
        XCTAssertNoThrow(try sut.inspect().find(text: "Brief me"))
        XCTAssertThrowsError(try sut.inspect().find(viewWithAccessibilityIdentifier: "actionStrip.cheatSheetButton"))
    }

    func testEmptyStripWithFeatureOnShowsTheStatusLineAndNoEnableButton() async throws {
        let pool = try makePool()
        let sut = view(await stripVM(pool), rows: await dictionaryRows(pool), feature: .on(lastCheck: nil))

        XCTAssertNoThrow(try sut.inspect().find(ReactionCheatSheetView.self))
        XCTAssertNoThrow(try sut.inspect().find(text: "Watching your Slack reactions"))
        XCTAssertThrowsError(try sut.inspect().find(button: "Enable Reaction Commands"))
    }

    func testEnableButtonCallsBack() throws {
        var enabled = false
        // Labeled on purpose: a trailing closure would bind to the LAST
        // closure parameter, `onOpenSettings`, not `onEnable`.
        // swiftlint:disable:next trailing_closure
        let sut = ReactionCheatSheetView(rows: [], feature: .off, onEnable: { enabled = true })

        try sut.inspect().find(button: "Enable Reaction Commands").tap()

        XCTAssertTrue(enabled)
    }

    func testNonEmptyStripShowsNoInlineSheet() async throws {
        let pool = try makePool { db in
            try TestDatabase.insertAgentAction(db, tool: "brief_context", status: "pending")
            try TestDatabase.insertReactionCommandMapping(db, emoji: "pushpin", tool: "brief_context")
        }
        let vm = await stripVM(pool)
        XCTAssertFalse(vm.actionRows.isEmpty, "fixture must produce a non-empty strip")
        let sut = view(vm, rows: await dictionaryRows(pool), feature: .off)

        // The negative finds walk only the list and reading pane (the split's
        // columns after the rail): the folder menu holds no cheat sheet, and
        // walking it on every miss made this test take minutes.
        let inbox = try sut.inspect().vStack().hSplitView(1)
        XCTAssertThrowsError(try inbox.find(ReactionCheatSheetView.self), "no inline sheet among real cards")
        XCTAssertThrowsError(try inbox.find(button: "Enable Reaction Commands"))
        // The `?` itself sits on the pane headers and Needs approval's
        // header (`InboxPaneHeaderTests`, `ActionStripFolderPaneTests`).
    }

    /// One source of truth: a mapping the owner added in Settings (a custom
    /// emoji on an existing tool) is a cheat-sheet row; a disabled one is not.
    func testRowsComeFromTheLiveDictionaryAndOmitDisabledMappings() async throws {
        let pool = try makePool { db in
            try TestDatabase.insertReactionCommandMapping(db, emoji: "rocket", tool: "create_idea")
            try TestDatabase.insertReactionCommandMapping(db, emoji: "eyes", tool: "create_track", enabled: false)
        }
        let sut = view(await stripVM(pool), rows: await dictionaryRows(pool), feature: .on(lastCheck: nil))

        XCTAssertNoThrow(try sut.inspect().find(text: "Save as idea"))
        XCTAssertNoThrow(try sut.inspect().find(text: ":rocket:"))
        XCTAssertThrowsError(try sut.inspect().find(text: "Track this"), "a disabled mapping is omitted")
    }

    /// An empty legacy list (opened from the root, as a route to Messages
    /// does) shows its own empty state; the cheat sheet stays behind `?` there.
    func testEmptyLegacyListShowsItsOwnEmptyState() async throws {
        let suite = "ActionStripActionsViewTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let vm = ActionStripViewModel(dbPool: try makePool(), cliRunner: FakeCLIRunner(), defaults: defaults)
        await vm.refresh()
        vm.openLegacy(.messages)
        let sut = view(vm, rows: [], feature: .off)

        XCTAssertNoThrow(try sut.inspect().find(text: "No messages waiting"))
        XCTAssertThrowsError(try sut.inspect().find(ReactionCheatSheetView.self))
        XCTAssertNoThrow(try sut.inspect().find(viewWithAccessibilityIdentifier: "actionStrip.cheatSheetButton"))
        XCTAssertNoThrow(try sut.inspect().find(viewWithAccessibilityIdentifier: "inbox.emptyLegacyList"))
    }

    /// Before the first read the Inbox shows a spinner, never "empty" and
    /// the cheat sheet for a moment.
    func testBeforeTheFirstReadNoEmptyStateFlashes() async throws {
        let vm = ActionStripViewModel(dbPool: try makePool(), cliRunner: FakeCLIRunner())
        let sut = view(vm, rows: [], feature: .off)

        XCTAssertNoThrow(try sut.inspect().find(viewWithAccessibilityIdentifier: "inbox.loading"))
        XCTAssertThrowsError(try sut.inspect().find(ReactionCheatSheetView.self))
        XCTAssertThrowsError(try sut.inspect().find(viewWithAccessibilityIdentifier: "actionStrip.cheatSheet"))
        XCTAssertThrowsError(try sut.inspect().find(viewWithAccessibilityIdentifier: "inbox.folderList"))

        await vm.refresh()
        XCTAssertThrowsError(try sut.inspect().find(viewWithAccessibilityIdentifier: "inbox.loading"))
        XCTAssertNoThrow(try sut.inspect().find(ReactionCheatSheetView.self), "after the read: the empty root")
    }

    /// The very first read fails: the reason and Try Again in place of the
    /// spinner, which would otherwise never end; Try Again's read lands.
    func testAFailedFirstReadShowsItsErrorNotASpinner() async throws {
        // An artifact, so the read reaches the folder view broken below.
        let pool = try makePool { db in
            let automation = try TestDatabase.insertAutomation(db, slug: "weekly", name: "Weekly mail roundup")
            let run = try TestDatabase.insertAutomationRun(db, automationID: automation)
            try TestDatabase.insertAutomationOutput(db, automationID: automation, runID: run)
        }
        let original = try await pool.read { db in
            try XCTUnwrap(String.fetchOne(
                db, sql: "SELECT sql FROM sqlite_master WHERE type = 'view' AND name = 'inbox_artifact_folders'"))
        }
        try await pool.write { db in
            try db.execute(sql: "DROP VIEW inbox_artifact_folders")
            try db.execute(sql: "CREATE VIEW inbox_artifact_folders AS SELECT 1 AS unrelated")
        }
        let vm = ActionStripViewModel(dbPool: pool, cliRunner: FakeCLIRunner())
        let sut = view(vm, rows: [], feature: .off)

        await vm.refresh()

        XCTAssertFalse(vm.hasRead)
        XCTAssertNotNil(vm.firstReadError)
        XCTAssertThrowsError(try sut.inspect().find(viewWithAccessibilityIdentifier: "inbox.loading"))
        XCTAssertNoThrow(try sut.inspect().find(viewWithAccessibilityIdentifier: "inbox.readFailed"))
        XCTAssertNoThrow(try sut.inspect().find(text: "The Inbox could not be read"))
        XCTAssertThrowsError(try sut.inspect().find(ReactionCheatSheetView.self), "never the empty Inbox")

        try await pool.write { db in
            try db.execute(sql: "DROP VIEW inbox_artifact_folders")
            try db.execute(sql: original)
        }
        try sut.inspect().find(button: "Try Again").tap()
        await vm.refresh()

        XCTAssertTrue(vm.hasRead)
        XCTAssertNil(vm.firstReadError)
        XCTAssertThrowsError(try sut.inspect().find(viewWithAccessibilityIdentifier: "inbox.readFailed"))
        XCTAssertThrowsError(try sut.inspect().find(viewWithAccessibilityIdentifier: "inbox.loading"))
        XCTAssertEqual(vm.outputRows.count, 1, "the read landed")
    }

    func testFeatureStateFollowsTheLoadedFeatureList() {
        func info(_ state: String) -> FeatureInfo {
            FeatureInfo(
                id: "reaction-commands", title: "", description: "", tagline: "", benefits: [], icon: "",
                state: state, core: false, parent: "", configKey: "reaction_commands.enabled", cost: "light",
                feedsInto: [], subToggles: []
            )
        }
        XCTAssertEqual(ReactionCheatSheetView.FeatureState.from(features: [], lastCheck: nil), .unknown)
        XCTAssertEqual(ReactionCheatSheetView.FeatureState.from(features: [info("disabled")], lastCheck: "x"), .off)
        XCTAssertEqual(
            ReactionCheatSheetView.FeatureState.from(features: [info("enabled")], lastCheck: "x"),
            .on(lastCheck: "x")
        )
    }

    /// The Messages entry stands in for Waiting for me (before its first
    /// run): its message card, drawn through the legacy split view, has
    /// Reply… for a Slack item (B Task 18).
    func testMessagesStandInCardHasReplyThroughTheLegacySplit() async throws {
        let suite = "ActionStripActionsViewTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var item: Int64 = 0
        let pool = try makePool { db in
            item = try TestDatabase.insertInboxItem(
                db, channelID: "1:C001", triggerType: "mention",
                permalink: "https://acme.slack.com/archives/C001/p1700000000000100")
            let id = try TestDatabase.insertAutomation(db, slug: "waiting-for-me")
            try db.execute(sql: """
                UPDATE automations SET origin = 'builtin', builtin_id = 'waiting-for-me', path = 'builtin:waiting-for-me'
                WHERE id = ?
                """, arguments: [id])
        }
        let vm = ActionStripViewModel(dbPool: pool, cliRunner: FakeCLIRunner(), defaults: defaults)
        vm.openLegacy(.messages)
        await vm.refresh()
        XCTAssertTrue(vm.folderMenu.snapshot.waitingForMe.messagesStandIn)
        vm.selection = .message(Int(item))
        let sut = view(vm, rows: [], feature: .off)

        XCTAssertNoThrow(try sut.inspect().find(InboxMessagePane.self), "the message card is shown")
        XCTAssertNoThrow(try sut.inspect().find(button: "Reply…"))
    }
}
