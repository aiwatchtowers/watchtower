import XCTest
import GRDB
@testable import WatchtowerCore
import WatchtowerTestSupport

/// The folder menu's model (inbox builder B, plan Task 11): every write goes
/// through `watchtower inbox folders …` at the read revision, a lost race
/// re-reads once and is never retried, refusals stay on the field or row,
/// drops are checked before any call.
@MainActor
final class InboxFolderMenuModelTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var ids: Ids!

    /// root > [Needs approval, Release > [Blockers > [Deep]], Team, Old (hidden) > [Old child]]
    private struct Ids {
        let root, approvals, release, blockers, deep, team, old, oldChild, automation: Int64
    }

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        ids = try pool.write { db in
            let seed = try InboxFolderFixtures.seed(db, revision: 7)
            let release = try InboxFolderFixtures.folder(db, parent: seed.root, slug: "release", position: 1, icon: "flag")
            let blockers = try InboxFolderFixtures.folder(db, parent: release, slug: "blockers", position: 0)
            let deep = try InboxFolderFixtures.folder(db, parent: blockers, slug: "deep", position: 0)
            let team = try InboxFolderFixtures.folder(db, parent: seed.root, slug: "team", position: 2)
            let old = try InboxFolderFixtures.folder(db, parent: seed.root, slug: "old", position: 3, hidden: true)
            let oldChild = try InboxFolderFixtures.folder(db, parent: old, slug: "old-child", position: 0)
            let automation = try TestDatabase.insertAutomation(db)
            try InboxFolderFixtures.route(db, automation: automation, folder: release)
            let run = try TestDatabase.insertAutomationRun(db, automationID: automation)
            try TestDatabase.insertAutomationOutput(db, automationID: automation, runID: run)
            return Ids(root: seed.root, approvals: seed.approvals, release: release, blockers: blockers, deep: deep,
                       team: team, old: old, oldChild: oldChild, automation: automation)
        }
    }

    override func tearDown() {
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    private func model(
        _ runner: (any CLIRunnerProtocol)?,
        noteLifetime: Duration = .seconds(60)
    ) async -> InboxFolderMenuModel {
        let model = InboxFolderMenuModel(dbPool: pool, runner: { runner }, noteLifetime: noteLifetime)
        await model.reload()
        return model
    }

    nonisolated private static func folderJSON(_ id: Int64) -> String {
        #"{"id":\#(id),"kind":"owner","slug":"f","title":"F","icon":"","parent_id":1,"position":1,"hidden":false,"#
            + #""automation_ids":[]}"#
    }

    /// Answers each verb with its pinned JSON.
    private func answering() -> ScriptedFolderCLI {
        ScriptedFolderCLI { args in
            switch args[2] {
            case "delete":
                #"{"revision":8,"moved":{"folders":0,"automations":0,"artifacts":0,"renamed":[]}}"#
            default:
                #"{"revision":8,"folder":\#(Self.folderJSON(99))}"#
            }
        }
    }

    private func setRevision(_ revision: Int64) throws {
        try pool.write { try $0.execute(sql: "UPDATE inbox_folder_state SET revision = ?", arguments: [revision]) }
    }

    // MARK: - Writes

    func testEachWriteSendsTheSpecArgumentsWithTheCurrentRevision() async {
        let cli = answering()
        let model = await model(cli)

        await model.create(title: "Acme", parent: nil)
        await model.create(title: "Inside", parent: ids.release)
        await model.rename(ids.team, title: "People")
        await model.setIcon(ids.team, icon: "bolt")
        await model.setHidden(ids.team, hidden: true)
        await model.setHidden(ids.old, hidden: false)
        await model.move(ids.team, toParent: ids.release, position: 0)
        await model.delete(ids.team)

        let revision = ["--expect-revision", "7", "--json"]
        XCTAssertEqual(cli.invocations, [
            ["inbox", "folders", "create", "--title", "Acme"] + revision,
            ["inbox", "folders", "create", "--title", "Inside", "--parent", "\(ids.release)"] + revision,
            ["inbox", "folders", "update", "\(ids.team)", "--title", "People"] + revision,
            ["inbox", "folders", "update", "\(ids.team)", "--icon", "bolt"] + revision,
            ["inbox", "folders", "update", "\(ids.team)", "--hidden=true"] + revision,
            ["inbox", "folders", "update", "\(ids.old)", "--hidden=false"] + revision,
            ["inbox", "folders", "move", "\(ids.team)", "--parent", "\(ids.release)", "--position", "0"] + revision,
            ["inbox", "folders", "delete", "\(ids.team)"] + revision
        ])
        XCTAssertNil(model.refusal)
        XCTAssertNil(model.note)
    }

    func testCreateFromTheDraftClosesTheFieldAndReloads() async throws {
        let ids = try XCTUnwrap(self.ids)
        let cli = ScriptedFolderCLI { _ in #"{"revision":8,"folder":\#(Self.folderJSON(99))}"# }
        let model = await model(cli)
        cli.onRun = { [pool] _ in
            try pool?.write { db in
                _ = try InboxFolderFixtures.folder(db, parent: ids.root, slug: "acme", position: 4)
                try db.execute(sql: "UPDATE inbox_folder_state SET revision = 8")
            }
        }

        model.beginCreate(parent: nil)
        model.editDraft("Acme")
        await model.commitDraft()

        XCTAssertNil(model.draft)
        XCTAssertEqual(model.tree.revision, 8)
        XCTAssertTrue(model.tree.folders.contains { $0.slug == "acme" })
    }

    func testConflictReloadsOnceAndSetsNote() async throws {
        let cli = ScriptedFolderCLI { _ in
            throw CLIRunnerError.nonZeroExit(
                code: 1, stderr: "the Inbox menu changed — reload it and try again (revision 8, you had 7)")
        }
        cli.onRun = { [pool] _ in
            try pool?.write { try $0.execute(sql: "UPDATE inbox_folder_state SET revision = 8") }
        }
        let model = await model(cli)

        await model.move(ids.team, toParent: ids.release, position: 0)

        XCTAssertEqual(cli.invocations.count, 1, "never retried")
        XCTAssertEqual(model.note, .menuChanged)
        XCTAssertEqual(model.content.note, .menuChanged)
        XCTAssertEqual(model.tree.revision, 8, "the tree re-read")
        XCTAssertNil(model.pendingMoveID)
        XCTAssertFalse(model.isBusy)
    }

    func testMenuChangedNoteLeavesAtTheNextDragOrAfterItsTime() async throws {
        let cli = ScriptedFolderCLI { _ in
            throw CLIRunnerError.nonZeroExit(code: 1, stderr: "the Inbox menu changed — reload it and try again")
        }
        let model = await model(cli)
        await model.setIcon(ids.team, icon: "bolt")
        XCTAssertEqual(model.note, .menuChanged)
        model.beginDrag(ids.team)
        XCTAssertNil(model.note, "the next drag")

        let short = await self.model(cli, noteLifetime: .milliseconds(20))
        await short.setIcon(ids.team, icon: "bolt")
        XCTAssertEqual(short.note, .menuChanged)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(short.note, "after its time")
    }

    func testRefusedWriteShowsMessage() async throws {
        let message = #"a folder named "Release" already exists here"#
        let cli = ScriptedFolderCLI { _ in throw CLIRunnerError.nonZeroExit(code: 1, stderr: message + "\n") }
        let model = await model(cli)
        let before = model.tree

        model.beginCreate(parent: nil)
        model.editDraft("release")
        await model.commitDraft()
        XCTAssertEqual(model.draft?.error, message, "create: the field stays with the message")
        XCTAssertEqual(model.draft?.title, "release")
        XCTAssertEqual(model.tree, before, "the tree unchanged")

        model.beginRename(ids.team)
        model.editDraft("Release")
        await model.commitDraft()
        XCTAssertEqual(model.draft?.target, .rename(ids.team))
        XCTAssertEqual(model.draft?.error, message, "rename: the field stays with the message")
        XCTAssertNil(model.note, "no reload line")
        model.editDraft("Release 2")
        XCTAssertNil(model.draft?.error, "the next edit clears it")

        model.cancelDraft()
        await model.setIcon(ids.team, icon: "bolt")
        XCTAssertEqual(model.content.refusal, InboxFolderMenuRefusal(folderID: ids.team, message: message),
                       "a row's refusal sits under the row")
        XCTAssertEqual(cli.invocations.count, 3)
    }

    func testWriteWhileBusyIsIgnored() async throws {
        let gate = Gate()
        let cli = ScriptedFolderCLI { _ in #"{"revision":8,"folder":\#(Self.folderJSON(99))}"# }
        cli.onRunAsync = { _ in await gate.wait() }
        let model = await model(cli)

        let first = Task { await model.setHidden(ids.team, hidden: true) }
        while !model.isBusy { await Task.yield() }
        XCTAssertTrue(model.isReadOnly)
        await model.setIcon(ids.team, icon: "bolt")
        await model.drop(ids.team, onto: InboxFolderDrop(targetID: ids.release, placement: .into))
        model.beginCreate(parent: nil)
        XCTAssertNil(model.draft, "no field while a write runs")
        await gate.open()
        await first.value

        XCTAssertEqual(cli.invocations.count, 1)
    }

    func testCLIMissingDisablesEditsKeepsReading() async {
        let model = await model(nil)

        XCTAssertEqual(model.content.note, .cliUnavailable)
        XCTAssertTrue(model.content.isReadOnly)
        XCTAssertTrue(model.isReadOnly)
        XCTAssertTrue(model.tree.folders.contains { $0.id == ids.release }, "reading works")
        model.select(ids.release)
        XCTAssertEqual(model.selectedFolderID, ids.release, "selecting works")
        model.beginCreate(parent: nil)
        model.beginRename(ids.team)
        model.askDelete(ids.team)
        XCTAssertNil(model.draft)
        XCTAssertNil(model.deleteConfirmation)
    }

    func testBinaryGoneAtThePressSetsTheCLINote() async {
        let cli = ScriptedFolderCLI { _ in throw CLIRunnerError.binaryNotFound }
        let model = await model(cli)

        await model.setIcon(ids.team, icon: "bolt")

        XCTAssertEqual(model.content.note, .cliUnavailable)
        XCTAssertTrue(model.isReadOnly)
    }

    func testUnexpectedAnswerReloadsAndShowsMessage() async throws {
        let ids = try XCTUnwrap(self.ids)
        let cli = ScriptedFolderCLI { _ in "not json" }
        cli.onRun = { [pool] _ in
            try pool?.write { db in
                _ = try InboxFolderFixtures.folder(db, parent: ids.root, slug: "acme", position: 4)
            }
        }
        let model = await model(cli)

        model.beginCreate(parent: nil)
        model.editDraft("Acme")
        await model.commitDraft()

        XCTAssertTrue(model.tree.folders.contains { $0.slug == "acme" }, "the write may have landed: re-read")
        XCTAssertNil(model.draft, "no second create from the same field")
        XCTAssertEqual(model.content.refusal?.message, "Unexpected answer from watchtower")
        XCTAssertEqual(cli.invocations.count, 1)
    }

    // MARK: - Drag

    func testDragBecomesMoveArguments() async {
        let cli = answering()
        let model = await model(cli)

        XCTAssertTrue(model.moveTarget(ids.team, onto: .init(targetID: ids.release, placement: .before))
            .map { $0 == (ids.root, 1) } ?? false, "before Release: after Needs approval")
        XCTAssertTrue(model.moveTarget(ids.team, onto: .init(targetID: ids.release, placement: .into))
            .map { $0 == (ids.release, 1) } ?? false, "into Release: its last child")
        XCTAssertTrue(model.moveTarget(ids.team, onto: .init(targetID: ids.root, placement: .into))
            .map { $0 == (ids.root, 3) } ?? false, "into the root: last")

        model.beginDrag(ids.team)
        model.dragOver(InboxFolderDrop(targetID: ids.release, placement: .before))
        XCTAssertEqual(model.content.dropIndicator, InboxFolderDrop(targetID: ids.release, placement: .before))
        await model.drop(ids.team, onto: InboxFolderDrop(targetID: ids.release, placement: .before))

        XCTAssertEqual(cli.invocations, [["inbox", "folders", "move", "\(ids.team)", "--parent", "\(ids.root)",
                                          "--position", "1", "--expect-revision", "7", "--json"]])
        XCTAssertNil(model.content.dropIndicator)
    }

    func testOnlyTheLiveDragsFolderMoves() async throws {
        let cli = answering()
        let model = await model(cli)
        let drop = InboxFolderDrop(targetID: ids.release, placement: .into)

        await model.drop(ids.team, onto: drop)
        XCTAssertTrue(cli.invocations.isEmpty, "no drag at all")

        model.beginDrag(ids.team)
        await model.drop(ids.blockers, onto: drop)
        XCTAssertTrue(cli.invocations.isEmpty, "the drop carried another folder than the drag")
        XCTAssertNil(model.draggedID, "a drop ends the drag either way")

        model.beginDrag(ids.team)
        model.endDrag()
        await model.drop(ids.team, onto: drop)
        XCTAssertTrue(cli.invocations.isEmpty, "a drag that ended moves nothing")
    }

    func testAForgottenDragIsClearedAfterItsLifetime() async throws {
        let cli = answering()
        let model = InboxFolderMenuModel(dbPool: pool, runner: { cli }, dragLifetime: .milliseconds(20))
        await model.reload()

        model.beginDrag(ids.team)
        XCTAssertEqual(model.draggedID, ids.team)
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertNil(model.draggedID, "a cancelled drag SwiftUI never reported")
        await model.drop(ids.team, onto: InboxFolderDrop(targetID: ids.release, placement: .into))
        XCTAssertTrue(cli.invocations.isEmpty, "a stale drag moves nothing")
    }

    func testDropPastTheDepthLimitIsRefusedLocally() async {
        let cli = answering()
        let model = await model(cli)

        model.beginDrag(ids.team)
        model.dragOver(InboxFolderDrop(targetID: ids.deep, placement: .into))
        XCTAssertNil(model.content.dropIndicator, "no indicator for a refused drop")
        XCTAssertFalse(model.canDrop(ids.team, onto: .init(targetID: ids.deep, placement: .into)), "depth 4")
        XCTAssertTrue(model.canDrop(ids.team, onto: .init(targetID: ids.deep, placement: .before)), "depth 3")
        XCTAssertFalse(model.canDrop(ids.release, onto: .init(targetID: ids.team, placement: .into)),
                       "Release carries two levels: 2 + 2 > 3")
        XCTAssertFalse(model.canDrop(ids.release, onto: .init(targetID: ids.deep, placement: .into)),
                       "into its own subtree")
        await model.drop(ids.team, onto: InboxFolderDrop(targetID: ids.deep, placement: .into))

        XCTAssertTrue(cli.invocations.isEmpty)
    }

    func testRootAndNeedsApprovalCannotBeDraggedOrDroppedAround() async {
        let cli = answering()
        let model = await model(cli)

        for fixed in [ids.root, ids.approvals] {
            XCTAssertFalse(model.canDrop(fixed, onto: .init(targetID: ids.team, placement: .into)))
            model.beginDrag(fixed)
            XCTAssertNil(model.draggedID)
        }
        XCTAssertFalse(model.canDrop(ids.team, onto: .init(targetID: ids.approvals, placement: .before)),
                       "nothing above Needs approval")
        XCTAssertFalse(model.canDrop(ids.team, onto: .init(targetID: ids.approvals, placement: .into)),
                       "nothing into Needs approval")
        XCTAssertFalse(model.canDrop(ids.team, onto: .init(targetID: ids.root, placement: .before)),
                       "the root has no siblings")
        await model.drop(ids.approvals, onto: .init(targetID: ids.team, placement: .into))
        XCTAssertTrue(cli.invocations.isEmpty)
    }

    func testMoveInProgressDrawsTheFolderInItsNewPlaceDimmedAndReadOnly() async {
        let gate = Gate()
        let cli = answering()
        cli.onRunAsync = { _ in await gate.wait() }
        let model = await model(cli)

        model.beginDrag(ids.team)
        let moving = Task { await model.drop(ids.team, onto: .init(targetID: ids.release, placement: .before)) }
        while model.pendingMoveID == nil { await Task.yield() }
        let content = model.content
        XCTAssertEqual(content.pendingMoveID, ids.team)
        XCTAssertTrue(content.isReadOnly)
        XCTAssertEqual(content.rows.map(\.id).prefix(3), [ids.root, ids.approvals, ids.team],
                       "the dropped folder in its new place")
        await gate.open()
        await moving.value
        XCTAssertNil(model.content.pendingMoveID)
    }

    // MARK: - Delete, selection, hidden

    func testDeleteSummaryCountsFromTheTree() async {
        let model = await model(answering())

        model.askDelete(ids.release)

        let summary = model.deleteConfirmation
        XCTAssertEqual(summary?.folders, 1)
        XCTAssertEqual(summary?.automations, 1)
        XCTAssertEqual(summary?.artifacts, 1)
        XCTAssertEqual(summary?.text, "Delete “Release”? Its 1 folder, 1 automation and 1 artifact move to Inbox.")
        model.askDelete(ids.blockers)
        XCTAssertEqual(model.deleteConfirmation?.text, "Delete “Blockers”? Its 1 folder move to Release.")
        model.askDelete(ids.approvals)
        XCTAssertNil(model.deleteSummary(ids.approvals), "Needs approval is never deleted")
    }

    func testAnOpenDeleteConfirmationRecountsOnEachRead() async throws {
        let ids = try XCTUnwrap(self.ids)
        let model = await model(answering())
        model.askDelete(ids.release)
        XCTAssertEqual(model.deleteConfirmation?.folders, 1)

        try pool.write { db in
            _ = try InboxFolderFixtures.folder(db, parent: ids.release, slug: "later", position: 1)
        }
        await model.reload()
        XCTAssertEqual(model.deleteConfirmation?.folders, 2, "the numbers follow the tree")

        model.askDelete(ids.team)
        try pool.write { try $0.execute(sql: "DELETE FROM inbox_folders WHERE id = ?", arguments: [ids.team]) }
        await model.reload()
        XCTAssertNil(model.deleteConfirmation, "the folder is gone")
    }

    func testDeletingTheSelectedFolderSelectsItsParent() async throws {
        let ids = try XCTUnwrap(self.ids)
        let cli = answering()
        cli.onRun = { [pool] _ in
            try pool?.write { db in
                try db.execute(sql: "UPDATE inbox_folders SET parent_id = ? WHERE id = ?",
                               arguments: [ids.release, ids.deep])
                try db.execute(sql: "DELETE FROM inbox_folders WHERE id = ?", arguments: [ids.blockers])
            }
        }
        let model = await model(cli)
        model.select(ids.blockers)
        model.askDelete(ids.blockers)

        await model.delete(ids.blockers)

        XCTAssertEqual(model.selectedFolderID, ids.release)
        XCTAssertNil(model.deleteConfirmation)
    }

    func testHiddenFoldersAbsentUntilShowHiddenFolders() async {
        let model = await model(answering())

        XCTAssertFalse(model.content.visibleRows.contains { $0.id == ids.old || $0.id == ids.oldChild })
        await model.perform(.showHiddenFolders, folderID: ids.root)
        let shown = model.content.visibleRows
        XCTAssertTrue(shown.contains { $0.id == ids.old && $0.hidden })
        XCTAssertTrue(shown.contains { $0.id == ids.oldChild })
        await model.perform(.hideHiddenFolders, folderID: ids.root)
        XCTAssertFalse(model.content.visibleRows.contains { $0.id == ids.old })
    }

    func testRowsCarryDepthsCountsAndCollapse() async {
        let model = await model(answering())

        let rows = model.content.rows
        XCTAssertEqual(rows.first { $0.id == ids.deep }?.depth, 3)
        XCTAssertEqual(rows.first { $0.id == ids.release }?.count, 1, "its unread artifact")
        model.toggleExpanded(ids.release)
        XCTAssertFalse(model.content.visibleRows.contains { $0.id == ids.blockers })
        XCTAssertEqual(model.content.selection, ids.root, "the root when nothing is selected")
    }

    func testPaneCommandsAreLeftToTheCaller() async {
        let model = await model(answering())
        let handled = await model.perform(.learnedRules, folderID: ids.root)
        let turnOff = await model.perform(.turnOff, folderID: ids.approvals)
        XCTAssertFalse(handled)
        XCTAssertFalse(turnOff)
    }

    // MARK: - Survives navigation

    func testStateSurvivesTheInboxLeavingTheScreen() async throws {
        let ids = try XCTUnwrap(self.ids)
        let gate = Gate()
        let cli = answering()
        cli.onRunAsync = { _ in await gate.wait() }
        cli.onRun = { [pool] _ in
            try pool?.write { db in
                _ = try InboxFolderFixtures.folder(db, parent: ids.root, slug: "acme", position: 4)
                try db.execute(sql: "UPDATE inbox_folder_state SET revision = 8")
            }
        }
        let strip = ActionStripViewModel(dbPool: pool, cliRunner: cli)
        await strip.refresh()
        let menu = strip.folderMenu
        menu.select(ids.team)
        menu.beginCreate(parent: nil)
        menu.editDraft("Acme")

        let write = Task { await menu.commitDraft() }
        while !menu.isBusy { await Task.yield() }
        strip.setOnScreen(false) // the Inbox leaves; the write keeps running
        await gate.open()
        await write.value
        strip.setOnScreen(true)
        await strip.refresh()

        XCTAssertTrue(strip.folderMenu === menu)
        XCTAssertTrue(strip.folderMenu.tree.folders.contains { $0.slug == "acme" })
        XCTAssertEqual(strip.folderMenu.selectedFolderID, ids.team)
        XCTAssertNil(strip.folderMenu.draft)
    }

    func testStripRefreshReadsTheMenuAndApprovalsFeature() async {
        let strip = ActionStripViewModel(dbPool: pool, cliRunner: answering())
        await strip.refresh()
        XCTAssertEqual(strip.folderMenu.tree.revision, 7)
        strip.disabledFeatures = [ActionStripViewModel.approvalsFeatureID]
        XCTAssertFalse(strip.folderMenu.content.approvalsEnabled)
    }
}

/// A CLI double answering per call; records every call's arguments.
private final class ScriptedFolderCLI: CLIRunnerProtocol, @unchecked Sendable {
    private let answer: @Sendable ([String]) throws -> String
    private let lock = NSLock()
    private var recorded: [[String]] = []
    /// Runs before the answer: the CLI's side effect on the database.
    var onRun: (@Sendable ([String]) throws -> Void)?
    /// Runs before the answer and may suspend (a call that takes time).
    var onRunAsync: (@Sendable ([String]) async -> Void)?

    init(answer: @escaping @Sendable ([String]) throws -> String) {
        self.answer = answer
    }

    var invocations: [[String]] {
        lock.withLock { recorded }
    }

    func run(args: [String]) async throws -> Data {
        lock.withLock { recorded.append(args) }
        if let onRunAsync { await onRunAsync(args) }
        try onRun?(args)
        return Data(try answer(args).utf8)
    }
}

/// Holds a call until the test opens it.
private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}
