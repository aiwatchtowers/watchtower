import XCTest
@testable import WatchtowerCore

/// `internal/instructions/testdata/remember_cases.json` is the shared fixture
/// of Go `ParseRemember`; the Swift twin must give the same answer for every
/// case (dual path, pinned from both sides).
final class RememberCommandFixtureTests: XCTestCase {
    private struct Case: Decodable {
        let text: String
        let ok: Bool
        let line: String
    }

    private static func cases() throws -> [Case] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("internal/instructions/testdata/remember_cases.json")
        return try JSONDecoder().decode([Case].self, from: Data(contentsOf: url))
    }

    func testRememberFixtureMatchesGo() throws {
        let all = try Self.cases()
        XCTAssertGreaterThanOrEqual(all.count, 14)
        for c in all {
            let got = RememberCommand.parse(c.text)
            XCTAssertEqual(got != nil, c.ok, "ok for \(c.text.debugDescription)")
            if c.ok { XCTAssertEqual(got, c.line, "line for \(c.text.debugDescription)") }
        }
    }

    func testEmptyRuleIsACommandWithAnEmptyLine() {
        XCTAssertEqual(RememberCommand.parse("remember:   "), "")
        XCTAssertNil(RememberCommand.parse("remember"))
    }
}
