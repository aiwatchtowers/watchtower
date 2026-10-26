import XCTest
@testable import WatchtowerDesktop

/// ⌘[ belongs to View → Back (#711; moved out of the Workbench menu by spec
/// 2026-10-26 §4): the focused session chat pane with a subagent open
/// publishes a pop action, which the command runs first.
@MainActor
final class WorkbenchCommandsBackTests: XCTestCase {
    func testPopsTheFocusedSubagentFirst() {
        XCTAssertEqual(WorkbenchMenuContext.backAction(popAvailable: true, paletteOpen: false, canShowAll: true), .popSubagent)
        XCTAssertEqual(WorkbenchMenuContext.backAction(popAvailable: true, paletteOpen: false, canShowAll: false), .popSubagent,
                       "a single workbench with no list to go back to still pops")
    }

    func testGoesBackWithoutAPopAction() {
        XCTAssertEqual(WorkbenchMenuContext.backAction(popAvailable: false, paletteOpen: false, canShowAll: true), .showAllWorkbenches)
        XCTAssertNil(WorkbenchMenuContext.backAction(popAvailable: false, paletteOpen: false, canShowAll: false))
    }

    func testPaletteOpenBlocksBoth() {
        XCTAssertNil(WorkbenchMenuContext.backAction(popAvailable: true, paletteOpen: true, canShowAll: true))
    }

    /// The menu is the only binding of ⌘[: no in-view key equivalent
    /// competes with it in the same window.
    func testCommandBracketBoundOnlyByTheMenu() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
            .standardizedFileURL.path
        let walker = try XCTUnwrap(FileManager.default.enumerator(atPath: root))
        var binders: [String] = []
        while let rel = walker.nextObject() as? String {
            guard rel.hasSuffix(".swift") else { continue }
            let text = try String(contentsOfFile: root + "/" + rel, encoding: .utf8)
            if text.contains(#".keyboardShortcut("[", modifiers: .command)"#) { binders.append(rel) }
        }
        XCTAssertEqual(binders, ["App/ItemShortcutCommands.swift"])
    }
}
