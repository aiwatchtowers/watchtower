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

    /// An image path stays a word of its own: adjacent tokens and a word glued to one get a space, punctuation and
    /// whitespace do not (review round 1).
    func testExpandedImagePathIsAWordOfItsOwn() {
        let payloads: [Int: PastePayload] = [1: .image(path: "/a-1.png"), 2: .image(path: "/a-2.png"), 3: .text("t")]
        let expand = { PasteTokens.expand($0, payloads: payloads) { $0 } }
        XCTAssertEqual(expand("[Image #1][Image #2]"), "/a-1.png /a-2.png")
        XCTAssertEqual(expand("look[Image #1]please"), "look /a-1.png please")
        XCTAssertEqual(expand("см.[Image #1]"), "см. /a-1.png", "a period before the path is not one after it")
        XCTAssertEqual(expand("🙂[Image #1]"), "🙂 /a-1.png")
        XCTAssertEqual(expand("see [Image #1]."), "see /a-1.png.")
        XCTAssertEqual(expand("[Image #1], ([Image #2])?"), "/a-1.png, (/a-2.png)?")
        XCTAssertEqual(expand("[[Image #1]] {[Image #2]}!"), "[/a-1.png] {/a-2.png}!")
        XCTAssertEqual(expand("(\"[Image #1]\")"), "(\"/a-1.png\")")
        XCTAssertEqual(expand("a\n[Image #1]\tb"), "a\n/a-1.png\tb")
        XCTAssertEqual(expand("x[Pasted text #3 +1 lines]y"), "xty", "a text paste is not spaced")
        XCTAssertEqual(expand("[Image #1]"), "/a-1.png")
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

    /// A token is live only when its number has a payload of the token's own kind (fix round 1).
    func testLiveNumbersAreKindAware() {
        let text = "[Image #1] [Pasted text #1 +3 lines] [Pasted text #2 +1 lines]"
        let kinds: [Int: PasteKind] = [1: .image, 2: .text]
        XCTAssertEqual(PasteTokens.liveNumbers(in: text, kinds: kinds), [1, 2])
        XCTAssertEqual(PasteTokens.liveNumbers(in: "[Pasted text #1 +3 lines]", kinds: kinds), [], "hand-typed, other kind")
        XCTAssertEqual(PasteTokens.deletionRange(backwardFrom: 10, in: text, kinds: kinds), NSRange(location: 0, length: 10))
        XCTAssertNil(PasteTokens.deletionRange(backwardFrom: 36, in: text, kinds: kinds), "a text token beside image #1")
        XCTAssertEqual(PastePayload.image(path: "/p").kind, .image)
        XCTAssertEqual(PastePayload.text("t").kind, .text)
    }

    /// A label held twice is no token: neither copy expands, is deleted whole or keeps its payload live (final fix).
    func testDuplicateLabelIsNoToken() {
        let text = "[Image #1] and [Image #1]"
        let kinds: [Int: PasteKind] = [1: .image]
        XCTAssertEqual(PasteTokens.liveNumbers(in: text, kinds: kinds), [])
        XCTAssertEqual(PasteTokens.expand(text, payloads: [1: .image(path: "/p.png")]) { $0 }, text)
        XCTAssertNil(PasteTokens.deletionRange(backwardFrom: 10, in: text, kinds: kinds))
        XCTAssertNil(PasteTokens.deletionRange(backwardFrom: 25, in: text, kinds: kinds))
        XCTAssertNil(PasteTokens.deletionRange(backwardFrom: 25, in: text, live: [1]))
        XCTAssertEqual(PasteTokens.liveNumbers(in: "[Image #1] [Pasted text #1 +2 lines]", kinds: kinds), [1],
                       "a label of the other kind is no copy")
        XCTAssertEqual(PasteTokens.heldNumbers(in: text, kinds: kinds), [1], "held, though not a token")
        XCTAssertEqual(PasteTokens.heldNumbers(in: "[Pasted text #1 +2 lines]", kinds: kinds), [])
    }

    /// The ranges the Mac field draws as pills: live tokens only, in order.
    func testLiveRangesAreTheLiveTokensOnly() {
        let kinds: [Int: PasteKind] = [1: .image, 2: .text]
        let text = "a [Image #1] b [Pasted text #2 +4 lines] [Pasted text #1 +3 lines] [Image #3]"
        XCTAssertEqual(PasteTokens.liveRanges(in: text, kinds: kinds),
                       [NSRange(location: 2, length: 10), NSRange(location: 15, length: 25)])
        XCTAssertEqual(PasteTokens.liveRanges(in: "[Image #1] [Image #1]", kinds: kinds), [], "a doubled label")
        XCTAssertEqual(PasteTokens.liveRanges(in: "", kinds: kinds), [])
        XCTAssertEqual(PasteTokens.liveRanges(in: "[Image #1]", kinds: [:]), [], "no payload")
    }
}
