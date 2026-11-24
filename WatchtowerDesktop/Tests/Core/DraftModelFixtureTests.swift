import Foundation
import XCTest
@testable import WatchtowerCore

/// Go↔Swift dual path: the owner-draft model is kept by the session host
/// (`internal/sessionhost/draft.go`, the authority), by `TerminalCenter`'s
/// mirror and by the test fake `FakeHostDelivery`; the Swift `DraftModel`
/// and the Go `draftModel` both read
/// `internal/sessionhost/testdata/draft_cases.json`.
final class DraftModelFixtureTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Expect: Decodable {
            let count: Int
            let exact: Bool
            let holds: Bool
        }
        struct Case: Decodable {
            let name: String
            let profile: String
            let keys: [String]
            let dialog: Bool
            let expect: Expect
        }
        let claudeCodeChecked: String
        let cases: [Case]
        enum CodingKeys: String, CodingKey {
            case cases
            case claudeCodeChecked = "claude_code_checked"
        }
    }

    func testDraftModelMatchesGoFixtures() throws {
        let url = URL(fileURLWithPath: #filePath) // …/WatchtowerDesktop/Tests/Core/<this file>
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("internal/sessionhost/testdata/draft_cases.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        XCTAssertFalse(fixture.claudeCodeChecked.isEmpty)
        XCTAssertFalse(fixture.cases.isEmpty)
        for c in fixture.cases {
            let profile: AgentInputProfile = switch c.profile {
            case "claude": .claude
            case "codex": .codex
            default: .unidentified // Go `ProfileFor` of a shell or an unknown agent
            }
            var draft = DraftModel()
            for key in c.keys {
                draft.feed(Array(key.utf8), profile: profile, dialog: c.dialog)
            }
            XCTAssertEqual(draft.count, c.expect.count, "\(c.name): count")
            XCTAssertEqual(draft.exact, c.expect.exact, "\(c.name): exact")
            XCTAssertEqual(draft.holdsText, c.expect.holds, "\(c.name): holds")
        }
    }

    /// The app's own clear (Task 7's `clear_first`) empties any draft, an
    /// inexact one and a pending `\` included.
    func testClearedByAppEmptiesAnyDraft() {
        var draft = DraftModel()
        draft.feed(Array("ab\\".utf8), profile: .claude, dialog: false)
        draft.feed([0x1B, 0x5B, 0x44], profile: .claude, dialog: false)
        XCTAssertTrue(draft.holdsText)

        draft.clearedByApp()

        XCTAssertEqual(draft, DraftModel())
        XCTAssertFalse(draft.holdsText)
        XCTAssertEqual(draft.feed([0x0D], profile: .claude, dialog: false), .submit, "no `\\` left pending")
    }
}
