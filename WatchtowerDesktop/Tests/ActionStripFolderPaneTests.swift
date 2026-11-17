import XCTest
import GRDB
import SwiftUI
import ViewInspector
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerInterface
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

    /// The owner folder `release` (3) the automation routes to.
    private static let release: Int64 = 3

    /// Go's case `name`: the root, Needs approval and the owner folder
    /// `release` that automation 1 routes to, with its artifact 1 ("Release
    /// checklist"), listed by the fake tower. The folder is selected and the
    /// artifact opened.
    private func fixture(_ name: String) async throws -> Fixture {
        let (pool, path) = try TestDatabase.createPool()
        paths.append(path)
        let tower = try FeedCaseTransport.seeded(name, pool: pool)
        let suite = "ActionStripFolderPaneTests.\(UUID().uuidString)"
        suites.append(suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let runner = FakeCLIRunner()
        let vm = ActionStripViewModel(dbPool: pool, cliRunner: runner, defaults: defaults)
        await vm.follow(tower)
        vm.selectFolder(Self.release)
        guard case let .artifact(card)? = vm.folderEntries.first else {
            XCTFail("the routed artifact is not listed: \(vm.folderEntries.map(\.id))")
            throw CancellationError()
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

    // MARK: - The target button

    func testPendingTargetProposalShowsWaitingInAFolder() async throws {
        // Artifact 1's target button with its proposal pending: Go says waiting.
        let fx = try await fixture("desktop_folder_pane_target_pending")
        let button = try view(fx.vm).inspect().find(ArtifactTargetButton.self)
        XCTAssertNoThrow(try button.find(text: "Waiting for approval"))
        XCTAssertThrowsError(try button.find(text: "Make a task"), "not idle")
    }

    func testAppliedTargetProposalWithItsTaskShowsTaskCreatedInAFolder() async throws {
        // Its proposal applied and the task there: Go says created.
        let fx = try await fixture("desktop_folder_pane_target_applied")
        let button = try view(fx.vm).inspect().find(ArtifactTargetButton.self)
        XCTAssertNoThrow(try button.find(text: "Task created"))
    }

    // MARK: - The composition

    /// One artifact through the folder pane: its list row's native actions,
    /// its ⋯, and a Reply whose reason names the artifact.
    func testFolderPaneDrawsRowActionsMenuAndReplyHost() async throws {
        // Artifact 1's list row is item 1, a Slack mention with its
        // permalink: Go's facts of the row give it Reply….
        let fx = try await fixture("desktop_folder_pane_reply_row")
        let item: Int64 = 1

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
