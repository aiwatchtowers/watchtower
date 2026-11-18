import GRDB
import XCTest
@testable import WatchtowerCore

/// Spec 2026-11-18 §6.4: the folder each start entry point picks.
final class NewSessionFolderTests: XCTestCase {
    private let home: Int64 = 1

    private func session(folder: Int64?) -> TerminalSession {
        var row = TerminalSession(
            id: 7, projectID: 1, kind: .claude, title: "Session", titleSource: .auto, targetID: nil,
            folderPath: "/tmp/hub", claudeSessionID: "uuid", createdAt: "2026-11-18T10:00:00Z",
            lastActiveAt: "2026-11-18T10:00:00Z"
        )
        row.workbenchFolderID = folder
        return row
    }

    private func target(folder: Int64?) -> Target {
        Target(row: Row(["id": 3, "text": "Export", "workbench_folder_id": folder]))
    }

    private func root(folder: Int64?) -> CodeRoot {
        let workbench = WorkbenchFolder(id: folder ?? home, workbenchID: 1, folderPath: "/tmp/f\(folder ?? home)",
                                        position: 0, name: "f")
        return CodeRoot(folder: workbench, homeFolderID: home)
    }

    func testNewSessionFolderFollowsTheCurrentSession() {
        let context = NewSessionFolder.Context.shortcut(currentSession: session(folder: 2), selectedRoot: root(folder: 3))
        XCTAssertEqual(NewSessionFolder.folderID(for: context, homeFolderID: home), 2, "⌘T in a hub session → hub")
        let legacy = NewSessionFolder.Context.shortcut(currentSession: session(folder: nil), selectedRoot: root(folder: 3))
        XCTAssertEqual(NewSessionFolder.folderID(for: legacy, homeFolderID: home), home,
                       "a row with no folder stored is home's, whatever root is open")
    }

    func testNewSessionFolderUsesTheSelectedRootWithoutASession() {
        let context = NewSessionFolder.Context.shortcut(currentSession: nil, selectedRoot: root(folder: 3))
        XCTAssertEqual(NewSessionFolder.folderID(for: context, homeFolderID: home), 3)
    }

    func testNewSessionFolderFallsBackToHome() {
        let context = NewSessionFolder.Context.shortcut(currentSession: nil, selectedRoot: nil)
        XCTAssertEqual(NewSessionFolder.folderID(for: context, homeFolderID: home), home)
        XCTAssertEqual(NewSessionFolder.folderID(for: .filesRoot(root(folder: nil)), homeFolderID: home), home)
    }

    func testWorkOnItUsesTheTargetsFolder() {
        XCTAssertEqual(NewSessionFolder.folderID(for: .workOnIt(target: target(folder: 2)), homeFolderID: home), 2)
    }

    func testWorkOnItWithoutAFolderUsesHome() {
        XCTAssertEqual(NewSessionFolder.folderID(for: .workOnIt(target: target(folder: nil)), homeFolderID: home), home)
    }

    func testFilesRootAndMenuItemUseTheirFolder() {
        XCTAssertEqual(NewSessionFolder.folderID(for: .filesRoot(root(folder: 3)), homeFolderID: home), 3)
        XCTAssertEqual(NewSessionFolder.folderID(for: .menu(folderID: 2), homeFolderID: home), 2)
    }

    func testResolveKeepsALiveFolderAndSendsAnUnknownOneHome() {
        let folders = BenchFolders(folders: [
            WorkbenchFolder(id: 1, workbenchID: 1, folderPath: "/tmp/app", position: 0, name: "app"),
            WorkbenchFolder(id: 2, workbenchID: 1, folderPath: "/tmp/hub", position: 1, name: "hub")
        ], homeID: 1)
        XCTAssertEqual(NewSessionFolder.resolve(2, folders: folders).folderID, 2)
        XCTAssertNil(NewSessionFolder.resolve(2, folders: folders).notice)
        XCTAssertEqual(NewSessionFolder.resolve(1, folders: folders).folderID, 1)
        XCTAssertEqual(NewSessionFolder.resolve(42, folders: folders).folderID, 1, "a folder of no bench: home")
    }
}
