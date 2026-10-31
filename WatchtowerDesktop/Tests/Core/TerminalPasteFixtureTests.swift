import Foundation
import XCTest
@testable import WatchtowerCore

/// Go↔Swift dual path: a line's cleaning for one bracketed paste is done by
/// both `WorkbenchCommentPrompt.terminalPayload` and the session host's
/// `PasteText`/`PastePayload` (`internal/sessionhost/paste.go`); both read
/// `internal/sessionhost/testdata/paste_cases.json`.
final class TerminalPasteFixtureTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Case: Decodable {
            let name: String
            let line: String
            let keepLineBreaks: Bool
            let keepFormat: Bool
            let want: String
            enum CodingKeys: String, CodingKey {
                case name, line, want
                case keepLineBreaks = "keep_line_breaks"
                case keepFormat = "keep_format"
            }
        }
        let cases: [Case]
    }

    func testTerminalPayloadMatchesGoFixtures() throws {
        let url = URL(fileURLWithPath: #filePath) // …/WatchtowerDesktop/Tests/Core/<this file>
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("internal/sessionhost/testdata/paste_cases.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        XCTAssertFalse(fixture.cases.isEmpty)
        let start: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]
        let end: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]
        for c in fixture.cases {
            XCTAssertEqual(
                WorkbenchCommentPrompt.terminalPayload(c.line, bracketedPaste: true, keepingLineBreaks: c.keepLineBreaks,
                                                       keepingFormatCharacters: c.keepFormat),
                .paste(start + Array(c.want.utf8) + end), c.name
            )
            XCTAssertEqual(
                WorkbenchCommentPrompt.terminalPayload(c.line, bracketedPaste: false, keepingLineBreaks: c.keepLineBreaks,
                                                       keepingFormatCharacters: c.keepFormat),
                .clipboard(c.want), c.name
            )
        }
    }
}
