import XCTest
@testable import WatchtowerCore

final class KeyboardShortcutCatalogTests: XCTestCase {
    func testNoChordRepeatsWithinAnArea() {
        for area in KeyboardShortcutCatalog.areas {
            let keys = area.entries.map(\.keys)
            XCTAssertEqual(Set(keys).count, keys.count, "a chord listed twice in \(area.title): \(keys)")
        }
    }

    func testAreasAreNamedOnceAndNoneIsEmpty() {
        let titles = KeyboardShortcutCatalog.areas.map(\.title)
        XCTAssertEqual(Set(titles).count, titles.count)
        for area in KeyboardShortcutCatalog.areas {
            XCTAssertFalse(area.entries.isEmpty, area.title)
            for entry in area.entries {
                XCTAssertFalse(entry.keys.trimmingCharacters(in: .whitespaces).isEmpty, area.title)
                XCTAssertFalse(entry.action.trimmingCharacters(in: .whitespaces).isEmpty, area.title)
                // A pipe would split the guide's table row.
                XCTAssertFalse(entry.keys.contains("|") || entry.action.contains("|"), entry.keys)
            }
        }
    }

    /// The areas the owner named (ask #194) are there.
    func testTheNamedAreasAreListed() {
        let titles = Set(KeyboardShortcutCatalog.areas.map(\.title))
        for title in ["Global", "AI Chat", "Targets", "Workbench", "Files Editor"] {
            XCTAssertTrue(titles.contains(title), title)
        }
    }

    /// The Workbench menu's chords (issue #288) are all listed.
    func testTheWorkbenchMenuChordsAreListed() throws {
        let workbench = try XCTUnwrap(KeyboardShortcutCatalog.areas.first { $0.title == "Workbench" })
        let keys = Set(workbench.entries.map(\.keys))
        for chord in ["⌘T", "⌘1–⌘9", "⌘K", "⌥⌘S", "⌘[", "⌃⌘A", "A"] {
            XCTAssertTrue(keys.contains(chord), chord)
        }
    }

    func testMarkdownRendersOneTablePerArea() {
        let markdown = KeyboardShortcutCatalog.markdown
        XCTAssertTrue(markdown.hasPrefix("### Global\n\n| Keys | Action |\n|---|---|\n| **⌘B** | Collapse or expand the menu |"))
        XCTAssertEqual(markdown.components(separatedBy: "\n### ").count, KeyboardShortcutCatalog.areas.count)
    }

    /// docs/guide/reference/keyboard-shortcuts.md carries the list verbatim; on a failure, paste
    /// `KeyboardShortcutCatalog.markdown` (printed below) into its
    /// "By area" section.
    func testTheGuideMatchesTheTable() throws {
        let guide = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/Core
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .deletingLastPathComponent() // the repository
            .appendingPathComponent("docs/guide/reference/keyboard-shortcuts.md")
        let text = try String(contentsOf: guide, encoding: .utf8)
        XCTAssertTrue(text.contains(KeyboardShortcutCatalog.markdown + "\n"),
                      "the guide's Keyboard Shortcuts section is out of date; expected:\n\(KeyboardShortcutCatalog.markdown)")
    }
}
