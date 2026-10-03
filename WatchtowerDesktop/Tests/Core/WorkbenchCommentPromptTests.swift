import XCTest
@testable import WatchtowerCore

final class WorkbenchCommentPromptTests: XCTestCase {
    func testOneLineTurnsControlAndNewlineScalarsIntoSpaces() {
        let line = WorkbenchCommentPrompt.oneLine("docs/a\nrm -rf x\r\u{1B}[2J\u{2028}\u{200B}.md")
        XCTAssertFalse(line.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) })
        XCTAssertEqual(line, "docs/a rm -rf x  [2J  .md")
    }

    func testBracketedPastePayloadWrapsTheCleanLineWithNoEnter() {
        let payload = WorkbenchCommentPrompt.terminalPayload("Address x\n\u{1B}y", bracketedPaste: true)
        let start: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]
        let end: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]
        XCTAssertEqual(payload, .paste(start + Array("Address xy".utf8) + end))
    }

    /// A line carrying its own paste terminator must not end the paste early:
    /// ESC is a control scalar, so it is dropped and only the literal rest stays.
    func testPastePayloadCannotContainTheTerminator() throws {
        let payload = WorkbenchCommentPrompt.terminalPayload("a\u{1B}[201~\r2", bracketedPaste: true)
        guard case let .paste(bytes) = payload else { return XCTFail("expected a paste") }
        let inner = Array(bytes.dropFirst(6).dropLast(6))
        XCTAssertFalse(inner.contains { $0 < 0x20 || $0 == 0x7F }, "no control byte, including ESC and CR")
        XCTAssertEqual(String(bytes: inner, encoding: .utf8), "a[201~2")
    }

    func testWithoutBracketedPasteTheCleanLineGoesToTheClipboard() {
        XCTAssertEqual(
            WorkbenchCommentPrompt.terminalPayload("Address x\n\u{1B}y", bracketedPaste: false),
            .clipboard("Address xy")
        )
    }

}
