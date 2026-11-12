import XCTest
import GRDB
import SwiftUI
import ViewInspector
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The Inbox's columns (inbox redesign, phase 1): the folder rail collapses
/// (`inbox.railHidden`), no "Inbox" title row sits over the list (the window
/// title holds it), and the reading column is the kit's readable width.
@MainActor
final class InboxLayoutTests: XCTestCase {
    private var paths: [String] = []
    private var suites: [String] = []

    override func tearDown() {
        paths.forEach { TestDatabase.cleanup(path: $0) }
        suites.forEach { UserDefaults.standard.removePersistentDomain(forName: $0) }
        paths = []
        suites = []
        super.tearDown()
    }

    private func stripVM(railHidden: Bool) async throws -> ActionStripViewModel {
        let (pool, path) = try TestDatabase.createPool()
        paths.append(path)
        let suite = "InboxLayoutTests.\(UUID().uuidString)"
        suites.append(suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        if railHidden { defaults.set(true, forKey: ActionStripViewModel.railHiddenKey) }
        let vm = ActionStripViewModel(dbPool: pool, cliRunner: FakeCLIRunner(), defaults: defaults)
        await vm.refresh()
        return vm
    }

    private func view(_ vm: ActionStripViewModel) -> ActionStripActionsView {
        ActionStripActionsView(
            vm: vm, cheatSheetRows: [], feature: .off, isEnabling: false, featureError: nil,
            onEnable: {}, onOpenSettings: {}, onOpen: { _ in })
    }

    func testRailHiddenLeavesTwoColumns() async throws {
        let hidden = try await stripVM(railHidden: true)
        XCTAssertTrue(hidden.railHidden)
        XCTAssertThrowsError(try view(hidden).inspect().find(InboxFolderMenuColumn.self))

        let shown = try await stripVM(railHidden: false)
        XCTAssertFalse(shown.railHidden, "the rail is shown by default")
        XCTAssertNoThrow(try view(shown).inspect().find(InboxFolderMenuColumn.self))
    }

    /// Toggling writes the per-viewer default the next launch reads.
    func testRailHiddenIsRemembered() async throws {
        let vm = try await stripVM(railHidden: false)
        vm.railHidden = true
        XCTAssertTrue(try XCTUnwrap(UserDefaults(suiteName: suites[0])).bool(forKey: ActionStripViewModel.railHiddenKey))
    }

    /// With the rail hidden nothing else draws the word: the old header row
    /// ("Inbox" + `?`) is gone.
    func testNoInboxTitleRowOverTheList() async throws {
        let vm = try await stripVM(railHidden: true)
        XCTAssertThrowsError(try view(vm).inspect().find(text: "Inbox"))
    }

    /// "Folders" heads the owner folders only once there is one; New
    /// Artifact… and the New Folder icon button sit at the bottom.
    func testRailFoldersHeadingAndBottomRow() throws {
        let seed = [
            InboxFolderRow(id: 1, kind: .root, title: "Inbox", icon: "", depth: 0, count: 0),
            InboxFolderRow(id: 2, kind: .approvals, title: "Needs approval", icon: "", depth: 1, count: 0)
        ]
        let release = InboxFolderRow(id: 3, kind: .owner, title: "Release", icon: "flag", depth: 1, count: 2)
        var actions: [InboxFolderMenuAction] = []
        let bare = InboxFolderMenu(content: InboxFolderMenuContent(rows: seed)) { actions.append($0) }
        XCTAssertThrowsError(try bare.inspect().find(text: "Folders"))
        try bare.inspect().find(button: "New Artifact…").tap()
        try bare.inspect().find(viewWithAccessibilityLabel: "New Folder").button().tap()
        XCTAssertEqual(actions, [.newArtifact, .newFolder])

        let withFolder = InboxFolderMenu(content: InboxFolderMenuContent(rows: seed + [release]))
        XCTAssertNoThrow(try withFolder.inspect().find(text: "Folders"))
    }

    func testReadingColumnIsTheReadableWidth() {
        XCTAssertEqual(InboxCardColumn<EmptyView>.readableWidth, ReadableColumn.maxLineWidth)
    }
}
