import XCTest
@testable import WatchtowerCore

/// Spec 2026-11-18 §6.4–§6.6: sub-sessions nested under their parent, the
/// folder labels, a child's strip, the agent message in a prompt and the
/// New Session menu per folder.
final class SessionNestingPresentationTests: XCTestCase {
    private typealias Copy = SessionNestingPresentation

    private func session(_ id: Int64, parent: Int64? = nil, folder: Int64? = nil) -> TerminalSession {
        var row = TerminalSession(
            id: id, projectID: 1, kind: .claude, title: "Session \(id)", titleSource: .auto, targetID: nil,
            folderPath: "/tmp/acme", claudeSessionID: "uuid", createdAt: "2026-11-18T10:00:00Z",
            lastActiveAt: "2026-11-18T10:00:00Z"
        )
        row.parentSessionID = parent
        row.workbenchFolderID = folder
        return row
    }

    private func bench(_ names: [String], removed: Set<String> = []) -> BenchFolders {
        let folders = names.enumerated().map { index, name in
            WorkbenchFolder(id: Int64(index + 1), workbenchID: 1, folderPath: "/tmp/\(name)", position: index,
                            removedAt: removed.contains(name) ? "2026-11-18T10:00:00Z" : nil, name: name)
        }
        return BenchFolders(folders: folders, homeID: 1)
    }

    // MARK: - Nesting

    func testNestingDepthAndOrphans() {
        // 1 ← 2 ← 4, 1 ← 3; 5's parent (9) is gone; 6 is top level.
        let rows = [session(4, parent: 2), session(1), session(5, parent: 9), session(3, parent: 1),
                    session(2, parent: 1), session(6)]
        let nested = Copy.nest(rows)
        XCTAssertEqual(nested.map(\.row.id), [1, 3, 2, 4, 5, 6], "children under their parent, siblings in list order")
        XCTAssertEqual(nested.map(\.depth), [0, 1, 1, 2, 0, 0], "a child of a deleted parent sits at the top")
    }

    func testNestingSurvivesALoop() {
        let nested = Copy.nest([session(1, parent: 2), session(2, parent: 1), session(3, parent: 3)])
        XCTAssertEqual(Set(nested.map(\.row.id)), [1, 2, 3], "every row once, never lost")
        XCTAssertEqual(nested.count, 3)
    }

    func testPanelNestsChildrenUnderTheirParent() {
        let sessions = [session(1), session(2), session(3, parent: 1)]
        let sections = SessionPanelSections.grouping(
            sessions: sessions, savedOrder: [1, 2, 3], statuses: [:], liveIDs: [1, 2, 3], now: Date(),
            expanded: false, sticky: nil
        )
        XCTAssertEqual(sections.main.map(\.id), [1, 3, 2])
        XCTAssertEqual(sections.main.map(\.depth), [0, 1, 0])
        XCTAssertEqual(sections.shortcutOrder, [1, 3, 2], "⌘1…⌘9 follow the nested order")
    }

    func testSubSessionsSuffix() {
        XCTAssertNil(Copy.subSessionsSuffix(0))
        XCTAssertEqual(Copy.subSessionsSuffix(1), "· 1 sub-session")
        XCTAssertEqual(Copy.subSessionsSuffix(2), "· 2 sub-sessions")
    }

    // MARK: - Folders

    func testOneFolderRowsHaveNoFolderLabel() {
        XCTAssertNil(Copy.folderLabel(folderID: 1, folders: bench(["app"])), "a one-folder bench looks as today")
        XCTAssertNil(Copy.folderLabel(folderID: nil, folders: bench(["app", "hub"], removed: ["hub"])),
                     "a removed folder does not count")
        XCTAssertNil(Copy.folderLabel(folderID: 1, folders: nil), "folders not read yet")
    }

    func testRowsOfSeveralFoldersNameTheirFolder() {
        let folders = bench(["app", "hub", "site"])
        XCTAssertEqual(Copy.folderLabel(folderID: 2, folders: folders), "hub")
        XCTAssertEqual(Copy.folderLabel(folderID: nil, folders: folders), "app", "no folder stored = home")
        XCTAssertNil(Copy.folderLabel(folderID: 42, folders: folders))
    }

    func testStripTrail() {
        XCTAssertEqual(Copy.stripTrail(folder: "hub", worktree: "export-api", branch: "wt/export-api", dirty: true),
                       "📁 hub › ⑂ export-api › ⎇ wt/export-api ●")
        XCTAssertEqual(Copy.stripTrail(folder: "hub", worktree: nil, branch: "main", dirty: false), "📁 hub › ⎇ main")
        XCTAssertEqual(Copy.stripTrail(folder: "hub", worktree: nil, branch: nil, dirty: false), "📁 hub")
    }

    func testFromParent() {
        XCTAssertEqual(Copy.fromParent(title: "Export reports to PDF"), "↖ from “Export reports to PDF”")
    }

    // MARK: - An agent message in the prompt

    func testPromptStrings() {
        XCTAssertEqual(Copy.promptWaiting, "· Agent message waiting in the prompt")
        XCTAssertEqual(Copy.promptNotice, "An agent's message is in the prompt. Press Return in the terminal to send it.")
        XCTAssertEqual(Copy.showInTerminal, "Show in Terminal")
        XCTAssertEqual(Copy.dismiss, "Dismiss")
    }

    func testDismissOnlyWithAnOldHost() {
        XCTAssertTrue(Copy.offersDismiss(hostHasPromptState: false))
        XCTAssertFalse(Copy.offersDismiss(hostHasPromptState: true))
    }

    // MARK: - New Session (+)

    func testNewSessionMenuAddsOneSubmenuPerOtherFolder() {
        let menu = Copy.newSessionMenu(folders: bench(["app", "hub", "site"]), contextFolderID: 1)
        XCTAssertEqual(menu.contextFolderID, 1)
        XCTAssertEqual(menu.otherFolders.map(\.title), ["in hub", "in site"])
        XCTAssertEqual(menu.otherFolders.map(\.folderID), [2, 3])
        let fromHub = Copy.newSessionMenu(folders: bench(["app", "hub", "site"]), contextFolderID: 2)
        XCTAssertEqual(fromHub.otherFolders.map(\.title), ["in app", "in site"], "the context folder is the top items'")
        XCTAssertEqual(Copy.folderSubmenuTitle("hub"), "in hub")
    }

    func testOneFolderMenuIsTodays() {
        let menu = Copy.newSessionMenu(folders: bench(["app"]), contextFolderID: 1)
        XCTAssertTrue(menu.otherFolders.isEmpty)
        XCTAssertTrue(menu.placementFolders.isEmpty, "the placement submenus hold the agents, as today")
        let removed = Copy.newSessionMenu(folders: bench(["app", "hub"], removed: ["hub"]), contextFolderID: 1)
        XCTAssertTrue(removed.otherFolders.isEmpty, "a removed folder gets no submenu")
    }

    func testPlacementSubmenusListTheFolders() {
        let menu = Copy.newSessionMenu(folders: bench(["app", "hub", "site"], removed: ["site"]), contextFolderID: 2)
        XCTAssertEqual(menu.placementFolders.map(\.title), ["app", "hub"], "every live folder, in position order")
        XCTAssertEqual(menu.placementFolders.map(\.folderID), [1, 2])
    }
}
