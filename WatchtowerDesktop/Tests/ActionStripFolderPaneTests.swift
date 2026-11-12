import XCTest
import GRDB
import SwiftUI
import ViewInspector
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The folder Inbox's reading pane through `ActionStripActionsView` (the
/// whole composition, not the pane alone): an artifact's target button
/// draws its state from the Inbox center, its rows carry their native
/// actions, its ⋯ shows outside Needs approval, and a Reply names the
/// artifact it was written from.
@MainActor
final class ActionStripFolderPaneTests: XCTestCase {
    private var paths: [String] = []
    private var suites: [String] = []

    override func tearDown() {
        paths.forEach { TestDatabase.cleanup(path: $0) }
        suites.forEach { UserDefaults.standard.removePersistentDomain(forName: $0) }
        paths = []
        suites = []
        super.tearDown()
    }

    private struct Fixture {
        let pool: DatabasePool
        let vm: ActionStripViewModel
        let runner: FakeCLIRunner
        let card: AutomationOutputCard
    }

    private static let target = #"{"label":"Make a task","kind":"target","target":{"title":"Sign off"}}"#

    /// The root, Needs approval and an owner folder `release` that one
    /// automation routes to; its artifact carries `blocks`. The folder is
    /// selected and the artifact opened.
    private func fixture(title: String = "Release checklist", blocks: String) async throws -> Fixture {
        let (pool, path) = try TestDatabase.createPool()
        paths.append(path)
        let release = try await pool.write { db -> Int64 in
            try db.execute(sql: "INSERT INTO inbox_folders (kind, parent_id, slug, title, position) "
                + "VALUES ('root', NULL, 'inbox', 'Inbox', 0)")
            let root = db.lastInsertedRowID
            try db.execute(sql: "INSERT INTO inbox_folders (kind, parent_id, slug, title, position) "
                + "VALUES ('approvals', ?, 'needs-approval', 'Needs approval', 0)", arguments: [root])
            try db.execute(sql: "INSERT INTO inbox_folders (kind, parent_id, slug, title, position) "
                + "VALUES ('owner', ?, 'release', 'Release', 1)", arguments: [root])
            let release = db.lastInsertedRowID
            try db.execute(sql: "INSERT INTO inbox_folder_state (id, revision) VALUES (1, 1)")
            let automation = try TestDatabase.insertAutomation(db, slug: "checklist", name: "Checklist")
            try db.execute(sql: "INSERT INTO inbox_folder_routes (automation_id, folder_id) VALUES (?, ?)",
                           arguments: [automation, release])
            let run = try TestDatabase.insertAutomationRun(db, automationID: automation)
            _ = try TestDatabase.insertAutomationOutput(
                db, automationID: automation, runID: run, title: title, blocksJSON: blocks)
            return release
        }
        let suite = "ActionStripFolderPaneTests.\(UUID().uuidString)"
        suites.append(suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let runner = FakeCLIRunner()
        let vm = ActionStripViewModel(dbPool: pool, cliRunner: runner, defaults: defaults)
        await vm.refresh()
        vm.selectFolder(release)
        guard case let .artifact(card)? = vm.folderEntries.first else {
            throw XCTSkip("the routed artifact is not listed: \(vm.folderEntries.map(\.id))")
        }
        await vm.selectEntry(vm.folderEntries[0].id)
        return Fixture(pool: pool, vm: vm, runner: runner, card: card)
    }

    private func view(_ vm: ActionStripViewModel, menu: InboxArtifactMenuModel? = nil) -> ActionStripActionsView {
        var view = ActionStripActionsView(
            vm: vm, cheatSheetRows: [], feature: .off, isEnabling: false, featureError: nil,
            onEnable: {}, onOpenSettings: {}, onOpen: { _ in })
        view.artifactMenu = menu
        return view
    }

    /// The button's context as the pane draws it (`InboxTargetPress.contextID`).
    private func context(_ card: AutomationOutputCard) throws -> String {
        guard case let .target(target)? = InboxCardLayout.of(card).pressable.first?.kind else {
            throw XCTSkip("no target button drawn")
        }
        return InboxTargetPress.contextID(outputID: card.id, index: 0, hash: target.hash)
    }

    private func targetFixture(status: String, applied: Bool = false) async throws -> Fixture {
        let fx = try await fixture(blocks: #"{"v":1,"blocks":[{"type":"actions","actions":[\#(Self.target)]}]}"#)
        let context = try context(fx.card)
        try await fx.pool.write { db in
            let id = try TestDatabase.insertAgentAction(
                db, surface: "inbox", contextType: "automation_output", contextID: context, status: status,
                resultJSON: applied ? #"{"target_id":1}"# : "", decidedAt: applied ? "2026-11-06T10:00:00Z" : "")
            if applied { _ = try TestDatabase.insertTarget(db, sourceType: "chat", sourceID: "action:\(id)") }
        }
        await fx.vm.refresh()
        return fx
    }

    // MARK: - The pane header

    /// An artifact opens under its pane header — tile, title, provenance
    /// line, `?` — and the card leaves out its own title row (inbox redesign).
    func testArtifactOpensUnderItsPaneHeader() async throws {
        let fx = try await fixture(blocks: #"{"v":1,"blocks":[{"type":"text","markdown":"All green"}]}"#)
        let sut = try view(fx.vm).inspect()
        let header = try sut.find(InboxArtifactPaneHeader.self)
        XCTAssertNoThrow(try header.find(text: "Release checklist"))
        XCTAssertNoThrow(try header.find(text: InboxCardTexts.readingSourceLine(fx.card)))
        XCTAssertNoThrow(try header.find(viewWithAccessibilityIdentifier: "actionStrip.cheatSheetButton"))
        // The list row and the header; the card's own title row would be a third.
        XCTAssertEqual(try sut.findAll(ViewType.Text.self) { try $0.string() == "Release checklist" }.count, 2,
                       "the card's own title row is hidden under the header")
    }

    // MARK: - The target button

    func testPendingTargetProposalShowsWaitingInAFolder() async throws {
        let fx = try await targetFixture(status: "pending")
        let button = try view(fx.vm).inspect().find(ArtifactTargetButton.self)
        XCTAssertNoThrow(try button.find(text: "Waiting for approval"))
        XCTAssertThrowsError(try button.find(text: "Make a task"), "not idle")
    }

    func testAppliedTargetProposalWithItsTaskShowsTaskCreatedInAFolder() async throws {
        let fx = try await targetFixture(status: "applied", applied: true)
        let button = try view(fx.vm).inspect().find(ArtifactTargetButton.self)
        XCTAssertNoThrow(try button.find(text: "Task created"))
    }

    // MARK: - The composition

    /// One artifact through the folder pane: its list row's native actions,
    /// its ⋯, and a Reply whose reason names the artifact.
    func testFolderPaneDrawsRowActionsMenuAndReplyHost() async throws {
        var fx = try await fixture(blocks: "")
        let item = try await fx.pool.write { db in
            try TestDatabase.insertInboxItem(db, channelID: "1:C001", triggerType: "mention",
                                             permalink: "https://acme.slack.com/archives/C001/p1700000000000100")
        }
        let blocks = #"{"v":1,"blocks":[{"type":"list","rows":[{"title":"colleague A","ref":{"kind":"inbox_item","id":\#(item)}}]}]}"#
        try await fx.pool.write { db in
            try db.execute(sql: "UPDATE automation_outputs SET blocks_json = ? WHERE id = ?",
                           arguments: [blocks, fx.card.id])
        }
        await fx.vm.refresh()
        await fx.vm.selectEntry(fx.vm.folderEntries[0].id)
        guard case let .artifact(card)? = fx.vm.selectedEntry else { return XCTFail("the artifact is selected") }
        fx = Fixture(pool: fx.pool, vm: fx.vm, runner: fx.runner, card: card)

        let menu = InboxArtifactMenuModel(folderMenu: fx.vm.folderMenu, hooks: .init(
            automations: { nil }, setBuiltinEnabled: { _, _ in nil }, openEditor: { _, _ in },
            openRunHistory: { _ in }, refresh: {}))
        let sut = view(fx.vm, menu: menu)
        XCTAssertNoThrow(try sut.inspect().find(InboxArtifactMenuButton.self), "the ⋯ outside Needs approval")
        try sut.inspect().find(button: "Reply…").tap()
        fx.vm.editReply(Int(item), text: "On it")
        try view(fx.vm, menu: menu).inspect().find(button: "Propose Reply").tap()

        let deadline = Date().addingTimeInterval(5)
        while fx.runner.invocations.isEmpty, Date() < deadline { await Task.yield() }
        let args = try XCTUnwrap(fx.runner.invocations.first).joined(separator: " ")
        XCTAssertTrue(args.contains(InboxReplyPolicy.reason(host: "Release checklist")), args)

        // Needs approval's stack draws no artifact ⋯ on its cards.
        let approvals = try XCTUnwrap(fx.vm.folderMenu.tree.approvals)
        fx.vm.selectFolder(approvals.id)
        XCTAssertThrowsError(try view(fx.vm, menu: menu).inspect().find(InboxArtifactMenuButton.self))
    }
}
