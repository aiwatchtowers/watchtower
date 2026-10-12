import GRDB
import XCTest
@testable import WatchtowerCore

final class CodeRootPolicyTests: XCTestCase {
    private let workbench = Workbench(row: Row(["id": 7, "name": "acme", "folder_path": "/tmp/acme"]))

    private func layout(_ primary: WorkspacePane, _ secondary: WorkspacePane? = nil, expanded: WorkspacePane? = nil) -> WorkspaceLayout {
        WorkspaceLayout(primary: primary, secondary: secondary, expanded: expanded, dividerFraction: 0.5)
    }

    func testActiveSessionFromLayout() {
        let cases: [(String, WorkspaceLayout, [Int64], Int64?)] = [
            ("single session", layout(.session(1)), [], 1),
            ("session report alone", layout(.sessionReport(4)), [], 4),
            ("split with board", layout(.board, .session(2)), [], 2),
            ("expanded Files over a session split", layout(.session(3), .files, expanded: .files), [], 3),
            ("session and its own report", layout(.session(5), .sessionReport(5)), [9], 5),
            ("two sessions, last focused", layout(.session(1), .session(2)), [2, 1], 1),
            ("two sessions, other focused last", layout(.session(1), .session(2)), [1, 2, 8], 2),
            ("two sessions, none focused", layout(.session(1), .sessionReport(2)), [8], 1),
            ("board only", layout(.board), [1], nil),
            ("board and Files", layout(.board, .files), [1], nil)
        ]
        for (name, layout, focus, want) in cases {
            XCTAssertEqual(CodeRootPolicy.activeSessionID(layout: layout, focusOrder: focus), want, name)
        }
    }

    func testRootTable() {
        let worktree = URL(fileURLWithPath: "/tmp/acme-wt/mobile-a", isDirectory: true)
        let exists: (URL) -> Bool = { $0.path == worktree.path || $0.path == "/tmp/acme" }
        let main = workbench.mainCodeRoot

        let hit = CodeRootPolicy.root(workbench: workbench, worktreeFolder: worktree, folderExists: exists)
        XCTAssertFalse(hit.isMain)
        XCTAssertEqual(hit.workbenchID, 7)
        XCTAssertEqual(hit, CodeRoot(workbenchID: 7, worktree: worktree))

        let missing = URL(fileURLWithPath: "/tmp/acme-wt/gone", isDirectory: true)
        XCTAssertEqual(CodeRootPolicy.root(workbench: workbench, worktreeFolder: missing, folderExists: exists), main, "missing")
        XCTAssertEqual(CodeRootPolicy.root(workbench: workbench, worktreeFolder: nil, folderExists: exists), main, "main/outside/unknown/removed")
        let itself = URL(fileURLWithPath: "/tmp/acme/", isDirectory: true)
        XCTAssertEqual(CodeRootPolicy.root(workbench: workbench, worktreeFolder: itself, folderExists: exists), main, "the workbench folder")
    }

    func testRootUsesTheRealDirectory() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("coderoot-\(UUID().uuidString)")
        let real = base.appendingPathComponent("wt")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        let link = base.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let viaReal = CodeRootPolicy.root(workbench: workbench, worktreeFolder: real)
        let viaLink = CodeRootPolicy.root(workbench: workbench, worktreeFolder: link)
        XCTAssertFalse(viaReal.isMain)
        XCTAssertEqual(viaReal, viaLink)
        XCTAssertEqual(CodeTabs.key(root: viaReal), CodeTabs.key(root: viaLink))
    }

    func testMainRootIsTheWorkbenchFolder() {
        let main = workbench.mainCodeRoot
        XCTAssertTrue(main.isMain)
        XCTAssertEqual(main.workbenchID, 7)
        XCTAssertEqual(main.folder.path, "/tmp/acme")
        XCTAssertEqual(main.defaultsKeySuffix, "")
    }
}
