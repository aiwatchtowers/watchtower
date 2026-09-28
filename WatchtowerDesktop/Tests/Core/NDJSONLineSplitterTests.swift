import XCTest
@testable import WatchtowerCore

final class NDJSONLineSplitterTests: XCTestCase {
    /// U+0085 (NEL), U+2028 and `\r` inside a line never split it — Go's
    /// `json.Marshal` leaves NEL raw.
    func testSplitsOnNewlineByteOnly() {
        var splitter = NDJSONLineSplitter()
        let line = "{\"type\":\"text_delta\",\"turn_id\":\"t\",\"text\":\"a\u{85}b\u{2028}c\"}"
        let lines = splitter.append(Array((line + "\n").utf8))
        XCTAssertEqual(lines, [line])
        XCTAssertEqual(ChatEvent.parse(lines[0]), .textDelta(turnID: "t", text: "a\u{85}b\u{2028}c"))
        // A raw carriage return is not a frame boundary either.
        XCTAssertEqual(splitter.append(Array("x\ry\n".utf8)), ["x\ry"])
    }

    /// A line (and a multi-byte character) split across reads is reassembled.
    func testKeepsPartialLinesAcrossReads() {
        var splitter = NDJSONLineSplitter()
        let bytes = Array("héllo\nwor\u{85}ld\nta".utf8)
        let cut = 2 // inside "é"
        XCTAssertEqual(splitter.append(bytes[..<cut]), [])
        XCTAssertEqual(splitter.append(bytes[cut...]), ["héllo", "wor\u{85}ld"])
        XCTAssertEqual(splitter.finish(), "ta")
        XCTAssertNil(splitter.finish())
    }

    func testEmptyInputAndBlankLines() {
        var splitter = NDJSONLineSplitter()
        XCTAssertEqual(splitter.append([]), [])
        XCTAssertEqual(splitter.append(Array("\n\n".utf8)), ["", ""])
        XCTAssertNil(splitter.finish())
    }
}
