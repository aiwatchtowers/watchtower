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
        struct App: Decodable {
            let after: Int
            let line: String
            let pause: Bool
        }
        struct Case: Decodable {
            let name: String
            let profile: String
            let keys: [String]
            let dialog: Bool
            let app: App?
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
            let draft = Self.run(c, profile: profile)
            XCTAssertEqual(draft.count, c.expect.count, "\(c.name): count")
            XCTAssertEqual(draft.exact, c.expect.exact, "\(c.name): exact")
            XCTAssertEqual(draft.holdsText, c.expect.holds, "\(c.name): holds")
        }
    }

    /// Feeds the case's keys; its app line is pasted after `app.after` of
    /// them, as Go `promptState` reads it: left typed (inexact), or in its
    /// pause, where any key but a submit or Shift+Tab reaches the line
    /// (inexact) until the owner's Return sent it.
    private static func run(_ c: Fixture.Case, profile: AgentInputProfile) -> DraftModel {
        var draft = DraftModel()
        var inPause = false
        for index in 0...c.keys.count {
            if let app = c.app, app.after == index {
                let endsInBackslash = app.line.hasSuffix("\\")
                // Go `promptState.pasteLine`: a pause only into an empty prompt, never after a `\`.
                inPause = app.pause && !draft.holdsText && !endsInBackslash
                draft.appPasted(endingInBackslash: endsInBackslash)
                if !inPause { draft.markInexact() }
            }
            guard index < c.keys.count else { break }
            switch draft.feed(Array(c.keys[index].utf8), profile: profile, dialog: c.dialog) {
            case .submit: inPause = false
            case .edit where inPause: draft.markInexact()
            case .edit, .ignored, .neutral: break
            }
        }
        return draft
    }

    /// Review round 4: only a profile with `exactDraft` reads the run (its
    /// Backspace), so Codex and an unidentified agent keep none; a submit and
    /// an inexact key drop a long run's buffer (counted, never timed).
    func testTheRunIsKeptOnlyWhereReadAndDroppedAfterward() {
        let long = [UInt8](repeating: UInt8(ascii: "x"), count: 4096)
        for profile in [AgentInputProfile.codex, .unidentified] {
            var draft = DraftModel()
            draft.feed(long, profile: profile, dialog: false)
            XCTAssertEqual(draft.count, long.count)
            XCTAssertEqual(draft.runLength, 0)
        }

        var draft = DraftModel()
        draft.feed(long, profile: .claude, dialog: false)
        XCTAssertEqual(draft.runLength, long.count)
        draft.feed([0x0D], profile: .claude, dialog: false)
        XCTAssertEqual(draft.runCapacity, 0, "a submit keeps no buffer")
        draft.feed(long, profile: .claude, dialog: false)
        draft.feed([0x09], profile: .claude, dialog: false)
        XCTAssertEqual(draft.runCapacity, 0, "an inexact key keeps no buffer")
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
