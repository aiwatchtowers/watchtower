import XCTest
@testable import WatchtowerDesktop

/// The clipping rule every hub projection shares (mobile POC spec §4): a
/// capped text is cut at a grapheme boundary and ends in `…` with the clipped
/// flag; a capped list keeps its head and counts the rest.
final class SliceClipTests: XCTestCase {
    // MARK: - Text

    func testTextWithinTheCapIsUnchangedAndUnflagged() {
        let clip = SliceClip.text("acme", limit: 4)
        XCTAssertEqual(clip.text, "acme")
        XCTAssertNil(clip.clipped, "an unclipped field carries no flag key")
        XCTAssertNil(SliceClip.text("", limit: 4).clipped)
    }

    func testTextOverTheCapEndsInAnEllipsisAndIsFlagged() {
        let clip = SliceClip.text("acme export", limit: 5)
        XCTAssertEqual(clip.text, "acme…")
        XCTAssertEqual(clip.clipped, true)
    }

    func testANonPositiveCapKeepsNothing() {
        let clip = SliceClip.text("acme", limit: 0)
        XCTAssertEqual(clip.text, "")
        XCTAssertEqual(clip.clipped, true)
    }

    /// Review focus 4: RTL text, a ZWJ family emoji and combining accents,
    /// each n graphemes long, at a cap of n (kept) and n − 1 (clipped), and
    /// one grapheme more than the cap (clipped). A clip never breaks a
    /// grapheme: the kept part is a whole-Character prefix of the original.
    func testReviewFocus4ClipsAtAGraphemeBoundary() {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"
        let accent = "e\u{0301}"
        let samples: [(name: String, text: String)] = [
            ("rtl", "שלום עולם مرحبا"),
            ("zwj", String(repeating: family, count: 6)),
            ("combining", String(repeating: accent, count: 6) + "a\u{0308}\u{0323}"),
            ("mixed", "a" + family + accent + "ש" + family)
        ]
        for sample in samples {
            let count = sample.text.count
            let atCap = SliceClip.text(sample.text, limit: count)
            XCTAssertEqual(atCap.text, sample.text, "\(sample.name): n graphemes at a cap of n are kept")
            XCTAssertNil(atCap.clipped, sample.name)

            for limit in [count - 1, count - 2] {
                let clip = SliceClip.text(sample.text, limit: limit)
                XCTAssertEqual(clip.clipped, true, "\(sample.name) at \(limit)")
                XCTAssertEqual(clip.text.count, limit, "\(sample.name): the ellipsis counts toward the cap")
                XCTAssertEqual(clip.text.last, "…", sample.name)
                let kept = String(clip.text.dropLast())
                XCTAssertEqual(Array(kept), Array(sample.text.prefix(limit - 1)), "\(sample.name): whole graphemes")
                XCTAssertTrue(
                    sample.text.unicodeScalars.starts(with: kept.unicodeScalars),
                    "\(sample.name): the kept scalars are the original's, none dropped mid-grapheme"
                )
            }
        }
    }

    func testAFamilyEmojiIsNeverSplitIntoItsMembers() {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        let clip = SliceClip.text("ab" + family + "cd", limit: 4)
        XCTAssertEqual(clip.text, "ab" + family + "…")
        XCTAssertEqual(clip.clipped, true)
    }

    // MARK: - List

    func testListWithinTheCapHasNoMore() {
        let list = SliceClip.list([1, 2, 3], limit: 3)
        XCTAssertEqual(list.items, [1, 2, 3])
        XCTAssertNil(list.more, "an uncapped list carries no _more key")
    }

    func testListOverTheCapKeepsTheHeadAndCountsTheRest() {
        let list = SliceClip.list(Array(1...25), limit: 20)
        XCTAssertEqual(list.items, Array(1...20))
        XCTAssertEqual(list.more, 5)
    }
}
