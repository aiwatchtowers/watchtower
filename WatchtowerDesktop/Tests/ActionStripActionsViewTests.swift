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

    private func stripVM(_ pool: DatabasePool) -> ActionStripViewModel {
        let vm = ActionStripViewModel(dbPool: pool, cliRunner: FakeCLIRunner())
        vm.refresh()
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
        let sut = view(stripVM(pool), rows: await dictionaryRows(pool), feature: .off)

        XCTAssertNoThrow(try sut.inspect().find(ReactionCheatSheetView.self))
        XCTAssertNoThrow(try sut.inspect().find(button: "Enable Reaction Commands"))
        XCTAssertNoThrow(try sut.inspect().find(text: "Brief me"))
        XCTAssertThrowsError(try sut.inspect().find(viewWithAccessibilityIdentifier: "actionStrip.cheatSheetButton"))
    }

    func testEmptyStripWithFeatureOnShowsTheStatusLineAndNoEnableButton() async throws {
        let pool = try makePool()
        let sut = view(stripVM(pool), rows: await dictionaryRows(pool), feature: .on(lastCheck: nil))

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

    func testNonEmptyStripHidesTheSheetBehindTheHelpButton() async throws {
        let pool = try makePool { db in
            try TestDatabase.insertAgentAction(db, tool: "brief_context", status: "pending")
            try TestDatabase.insertReactionCommandMapping(db, emoji: "pushpin", tool: "brief_context")
        }
        let vm = stripVM(pool)
        XCTAssertFalse(vm.actionRows.isEmpty, "fixture must produce a non-empty strip")
        let sut = view(vm, rows: await dictionaryRows(pool), feature: .off)

        XCTAssertThrowsError(try sut.inspect().find(ReactionCheatSheetView.self), "no inline sheet among real cards")
        XCTAssertThrowsError(try sut.inspect().find(button: "Enable Reaction Commands"))
        XCTAssertNoThrow(try sut.inspect().find(viewWithAccessibilityIdentifier: "actionStrip.cheatSheetButton"))
    }

    /// One source of truth: a mapping the owner added in Settings (a custom
    /// emoji on an existing tool) is a cheat-sheet row; a disabled one is not.
    func testRowsComeFromTheLiveDictionaryAndOmitDisabledMappings() async throws {
        let pool = try makePool { db in
            try TestDatabase.insertReactionCommandMapping(db, emoji: "rocket", tool: "create_idea")
            try TestDatabase.insertReactionCommandMapping(db, emoji: "eyes", tool: "create_track", enabled: false)
        }
        let sut = view(stripVM(pool), rows: await dictionaryRows(pool), feature: .on(lastCheck: nil))

        XCTAssertNoThrow(try sut.inspect().find(text: "Save as idea"))
        XCTAssertNoThrow(try sut.inspect().find(text: ":rocket:"))
        XCTAssertThrowsError(try sut.inspect().find(text: "Track this"), "a disabled mapping is omitted")
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
}

/// A due reminder links the Slack message it was set from — never the raw
/// `<channel_id>@<message_ts>` ref, and nothing at all without one.
@MainActor
final class ReminderRowTests: XCTestCase {
    private var paths: [String] = []

    override func tearDown() {
        paths.forEach { TestDatabase.cleanup(path: $0) }
        paths = []
        super.tearDown()
    }

    private func reminderRow(messageRef: String) throws -> ReminderRow {
        let (pool, path) = try TestDatabase.createPool()
        paths.append(path)
        try pool.write { db in
            try db.execute(
                sql: "INSERT INTO reminders (message_ref, note, remind_at, status) VALUES (?, 'Ping Ann', '2000-01-01T00:00:00Z', 'pending')",
                arguments: [messageRef]
            )
        }
        let vm = ActionStripViewModel(dbPool: pool, cliRunner: FakeCLIRunner())
        vm.refresh()
        return ReminderRow(reminder: try XCTUnwrap(vm.reminderRows.first), vm: vm)
    }

    func testReminderWithAMessageRefLinksTheSlackMessage() throws {
        let sut = try reminderRow(messageRef: "1:C0ABC@1740000000.5")
        let link = try sut.inspect().find(ViewType.Link.self)
        XCTAssertEqual(try link.url().absoluteString, "https://slack.com/archives/C0ABC/p17400000005")
        XCTAssertThrowsError(try sut.inspect().find(text: "1:C0ABC@1740000000.5"), "the raw ref is not shown")
    }

    func testReminderWithAnEmptyMessageRefShowsNoLink() throws {
        let sut = try reminderRow(messageRef: "")
        XCTAssertNoThrow(try sut.inspect().find(text: "Ping Ann"))
        XCTAssertThrowsError(try sut.inspect().find(ViewType.Link.self))
    }
}
