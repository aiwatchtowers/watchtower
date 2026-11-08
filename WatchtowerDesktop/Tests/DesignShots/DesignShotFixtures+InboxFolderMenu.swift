import AppKit
import GRDB
import SwiftUI
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The folder menu's shots drawn from `InboxFolderMenuModel` (plan Task 11):
/// a test database holds the tree (tests write the folder tables; the
/// Desktop never does), a fake CLI answers the writes, and each state is
/// reached through the model's own presses. The menu's numbers are the
/// mockups' (b-01, b-04), laid over the read tree.
@MainActor
enum InboxFolderMenuShotFixtures {
    /// The folders a shot's database holds, in tree order.
    enum Folder: String, CaseIterable {
        case release, blockers, team, shortRelease, oldSprint
    }

    private static var poolPaths: [String] = []
    /// Writes held open for a shot (a move in progress); cancelled by `cleanUp`.
    private static var heldWrites: [Task<Void, Never>] = []

    static func cleanUp() {
        heldWrites.forEach { $0.cancel() }
        heldWrites = []
        poolPaths.forEach(TestDatabase.cleanup(path:))
        poolPaths = []
    }

    /// The model over a database with `folders` (ids by slug), after its
    /// first read, with the mockups' counts.
    static func model(
        _ folders: [Folder],
        runner: (any CLIRunnerProtocol)? = FakeCLIRunner(),
        routedToRelease: Int = 0,
        artifactsInRelease: Int = 0
    ) throws -> (InboxFolderMenuModel, [String: Int64]) {
        let (pool, path) = try TestDatabase.createPool()
        poolPaths.append(path)
        let ids = try pool.write { db in
            try seed(db, folders, routedToRelease: routedToRelease, artifactsInRelease: artifactsInRelease)
        }
        let model = InboxFolderMenuModel(dbPool: pool) { runner }
        spin(until: "the first read", model.tree.folders.count > 1) { await model.reload() }
        mockupCounts(model)
        return (model, ids)
    }

    /// The mockups' numbers on the folders the model read.
    static func mockupCounts(_ model: InboxFolderMenuModel) {
        let counts: [String: Int] = ["inbox": 9, "needs-approval": 3, "release": 2, "blockers": 1, "old-sprint": 4]
        var byID: [Int64: Int] = [:]
        for folder in model.tree.folders { byID[folder.id] = counts[folder.slug] ?? 0 }
        model.apply(InboxFolderMenuSnapshot(tree: model.tree, counts: byID, artifacts: model.snapshot.artifacts))
    }

    /// Runs `start` and the main run loop until `done` (the precedent of the
    /// automations shots: a model's async press reached from a sync shot).
    static func spin(until what: String, _ done: @autoclosure () -> Bool, start: @escaping @MainActor () async -> Void) {
        let task = Task { await start() }
        let deadline = Date().addingTimeInterval(5)
        while !done(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(done(), "the folder menu fixture did not reach \(what)")
        heldWrites.append(task)
    }

    private static func seed(
        _ db: Database,
        _ folders: [Folder],
        routedToRelease: Int,
        artifactsInRelease: Int
    ) throws -> [String: Int64] {
        try db.execute(sql: "INSERT INTO inbox_folders (kind, parent_id, slug, title, position) VALUES ('root', NULL, 'inbox', 'Inbox', 0)")
        let root = db.lastInsertedRowID
        try db.execute(sql: """
            INSERT INTO inbox_folders (kind, parent_id, slug, title, position)
            VALUES ('approvals', ?, 'needs-approval', 'Needs approval', 0)
            """, arguments: [root])
        try db.execute(sql: "INSERT INTO inbox_folder_state (id, revision) VALUES (1, 1)")
        var ids = ["inbox": root, "needs-approval": db.lastInsertedRowID]
        var position = 1
        func insert(_ slug: String, _ title: String, icon: String, parent: Int64, hidden: Bool = false) throws {
            let topLevel = parent == root
            try db.execute(sql: """
                INSERT INTO inbox_folders (kind, parent_id, slug, title, icon, position, hidden)
                VALUES ('owner', ?, ?, ?, ?, ?, ?)
                """, arguments: [parent, slug, title, icon, topLevel ? position : 0, hidden])
            if topLevel { position += 1 }
            ids[slug] = db.lastInsertedRowID
        }
        for folder in folders {
            switch folder {
            case .release: try insert("release", "Release acme 2.0", icon: "flag", parent: root)
            case .shortRelease: try insert("release", "Release", icon: "flag", parent: root)
            case .blockers: try insert("blockers", "Blockers", icon: "shippingbox", parent: ids["release"] ?? root)
            case .team: try insert("team", "Team", icon: "person.2", parent: root)
            case .oldSprint: try insert("old-sprint", "Old sprint", icon: "shippingbox", parent: root, hidden: true)
            }
        }
        if let release = ids["release"] {
            var automations: [Int64] = []
            for index in 0..<routedToRelease {
                let automation = try TestDatabase.insertAutomation(db, slug: "weekly-\(index)", name: "Weekly \(index)")
                try db.execute(sql: "INSERT INTO inbox_folder_routes (automation_id, folder_id) VALUES (?, ?)",
                               arguments: [automation, release])
                automations.append(automation)
            }
            for index in 0..<artifactsInRelease {
                guard let automation = automations.first else { break }
                let run = try TestDatabase.insertAutomationRun(db, automationID: automation)
                try TestDatabase.insertAutomationOutput(db, automationID: automation, runID: run,
                                                        title: "Release note \(index)")
            }
        }
        return ids
    }

    // MARK: - The states

    /// Each Task 11 menu shot's content, reached through the model.
    static func content(_ name: String) throws -> InboxFolderMenuContent {
        switch name {
        case "inbox-b-menu-root":
            return try model([.release, .blockers, .team]).0.content
        case "inbox-b-menu-hidden-shown":
            let (model, _) = try model([.release, .oldSprint])
            spin(until: "Show Hidden Folders", model.showsHidden) {
                await model.perform(.showHiddenFolders, folderID: model.tree.root.id)
            }
            return model.content
        case "inbox-b-menu-new-folder":
            let (model, _) = try model([])
            model.beginCreate(parent: nil)
            model.editDraft("Release acme 2.0")
            return model.content
        case "inbox-b-menu-drag":
            let (model, ids) = try model([.team, .release])
            let team = try XCTUnwrap(ids["team"]), release = try XCTUnwrap(ids["release"])
            model.beginDrag(team)
            model.dragOver(InboxFolderDrop(targetID: release, placement: .before))
            XCTAssertNotNil(model.dropIndicator)
            return model.content
        case "inbox-b-menu-changed":
            let runner = FakeCLIRunner(error: CLIRunnerError.nonZeroExit(
                code: 1, stderr: "the Inbox menu changed — reload it and try again (revision 2, you had 1)"))
            let (model, ids) = try model([.release], runner: runner)
            let release = try XCTUnwrap(ids["release"])
            spin(until: "the reload line", model.note == .menuChanged) {
                await model.setIcon(release, icon: "bolt")
            }
            mockupCounts(model)
            return model.content
        case "inbox-b-menu-cli-unavailable":
            return try model([.release], runner: nil).0.content
        case "inbox-b-menu-write-refused":
            let runner = FakeCLIRunner(error: CLIRunnerError.nonZeroExit(
                code: 1, stderr: #"a folder named "Release" already exists here"#))
            let (model, _) = try model([.shortRelease], runner: runner)
            model.beginCreate(parent: nil)
            model.editDraft("Release")
            spin(until: "the refusal", model.draft?.error != nil) { await model.commitDraft() }
            return model.content
        case "inbox-b-menu-move-pending":
            let runner = FakeCLIRunner()
            runner.blockUntilCancelled = true
            let (model, ids) = try model([.release, .team], runner: runner)
            let team = try XCTUnwrap(ids["team"]), release = try XCTUnwrap(ids["release"])
            model.beginDrag(team)
            spin(until: "the move in progress", model.pendingMoveID != nil) {
                await model.drop(team, onto: InboxFolderDrop(targetID: release, placement: .before))
            }
            return model.content
        case "inbox-b-folder-delete-confirm":
            let (model, ids) = try model([.release, .blockers, .team], routedToRelease: 3, artifactsInRelease: 5)
            let release = try XCTUnwrap(ids["release"])
            model.select(release)
            model.askDelete(release)
            XCTAssertNotNil(model.deleteConfirmation)
            return model.content
        default:
            throw ShotError.unknown(name)
        }
    }

    enum ShotError: Error { case unknown(String) }
}
