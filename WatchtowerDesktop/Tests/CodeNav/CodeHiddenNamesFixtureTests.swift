import XCTest
@testable import WatchtowerDesktop

/// The Go walk skips the same names as the FILES tree when a workbench is
/// not a git repository (spec §4): its list is pinned to the Swift one by
/// `internal/codewalk/testdata/hidden_names.json`, read by both suites.
final class CodeHiddenNamesFixtureTests: XCTestCase {
    func testGoFixtureEqualsTheTreesHiddenNames() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // CodeNav
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("internal/codewalk/testdata/hidden_names.json")
        let names = try JSONDecoder().decode([String].self, from: Data(contentsOf: url))
        XCTAssertEqual(names.count, Set(names).count, "the fixture lists each name once")
        XCTAssertEqual(Set(names), CodeFileTree.hiddenNames)
    }
}
