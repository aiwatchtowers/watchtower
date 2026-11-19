import Foundation
import XCTest
@testable import WatchtowerChatText

/// Inline paste tokens (#2065 §6): `[Image #N]` and `[Pasted text #N +L lines]` in the Workchat draft, deleted as
/// one unit when they have a payload, expanded on send; a bracket text with no payload is plain text.
final class PasteTokensTests: XCTestCase {
    func testLabels() {
        XCTAssertEqual(PasteTokens.imageLabel(1), "[Image #1]")
        XCTAssertEqual(PasteTokens.textLabel(2, lines: 42), "[Pasted text #2 +42 lines]")
    }

    func testLineCount() {
        XCTAssertEqual(PasteTokens.lineCount("one"), 1)
        XCTAssertEqual(PasteTokens.lineCount("x\ny"), 2)
        XCTAssertEqual(PasteTokens.lineCount("x\r\ny\n"), 2, "a closing line break adds no line")
        XCTAssertEqual(PasteTokens.lineCount(""), 0)
    }

    func testBackspaceAtTokenEndDeletesWholeToken() {
        let text = "fix this [Image #1] and"
        XCTAssertEqual(PasteTokens.deletionRange(backwardFrom: 19, in: text, live: [1]), NSRange(location: 9, length: 10))
        XCTAssertNil(PasteTokens.deletionRange(backwardFrom: 19, in: text, live: []))  // hand-typed: plain text
        XCTAssertNil(PasteTokens.deletionRange(backwardFrom: 8, in: text, live: [1]))
        XCTAssertNil(PasteTokens.deletionRange(backwardFrom: 18, in: text, live: [1]), "inside the token: one character")
    }

    func testBackspaceDeletesTextTokenAfterEmoji() {
        let text = "🙂 [Pasted text #3 +2 lines]"
        let end = (text as NSString).length
        XCTAssertEqual(PasteTokens.deletionRange(backwardFrom: end, in: text, live: [3]),
                       NSRange(location: 3, length: end - 3))
        XCTAssertNil(PasteTokens.deletionRange(backwardFrom: end + 5, in: text, live: [3]), "past the end")
    }

    func testNumbers() {
        XCTAssertEqual(PasteTokens.numbers(in: "a [Image #1] b [Pasted text #4 +2 lines] [Image #x] [image]"), [1, 4])
        XCTAssertEqual(PasteTokens.numbers(in: "nothing"), [])
    }

    func testExpandTextInlineImageToPath() {
        let out = PasteTokens.expand("a [Pasted text #2 +2 lines] b [Image #1]",
                                     payloads: [2: .text("x\ny"), 1: .image(path: "/tmp/p 1.png")]) { "\"\($0)\"" }
        XCTAssertEqual(out, "a x\ny b \"/tmp/p 1.png\"")
    }

    func testUnknownNumberStaysVerbatim() {
        let text = "see [Image #9] and [Pasted text #9 +1 lines]"
        XCTAssertEqual(PasteTokens.expand(text, payloads: [1: .image(path: "/p.png")]) { $0 }, text)
    }

    /// A token of the other kind than its payload is not that payload's token.
    func testKindMismatchStaysVerbatim() {
        let text = "[Image #1] [Pasted text #2 +1 lines]"
        let out = PasteTokens.expand(text, payloads: [1: .text("t"), 2: .image(path: "/p.png")]) { $0 }
        XCTAssertEqual(out, text)
    }
}
