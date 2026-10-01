import XCTest
@testable import WatchtowerCore

/// The word-level diff behind the `edit_confluence_page` card (spec
/// 2026-09-30 §6): deleted words struck through, inserted words added, and
/// every byte of both texts accounted for (whitespace included).
final class WordDiffTests: XCTestCase {
    private typealias Segment = WordDiff.Segment

    /// same + removed rebuilds `before`; same + added rebuilds `after`.
    private func assertReconstructs(
        _ segments: [Segment],
        before: String,
        after: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let old = segments.filter { $0.kind != .added }.map(\.text).joined()
        let new = segments.filter { $0.kind != .removed }.map(\.text).joined()
        XCTAssertEqual(old, before, "before is not rebuilt", file: file, line: line)
        XCTAssertEqual(new, after, "after is not rebuilt", file: file, line: line)
    }

    func testIdenticalTextIsOneSameSegment() {
        let segments = WordDiff.diff(before: "Ships on Friday.", after: "Ships on Friday.")
        XCTAssertEqual(segments, [Segment(kind: .same, text: "Ships on Friday.")])
    }

    func testInsertedWord() {
        let before = "Ships on Friday."
        let after = "Ships early on Friday."
        let segments = WordDiff.diff(before: before, after: after)
        XCTAssertEqual(segments, [
            Segment(kind: .same, text: "Ships "),
            Segment(kind: .added, text: "early "),
            Segment(kind: .same, text: "on Friday.")
        ])
        assertReconstructs(segments, before: before, after: after)
    }

    func testDeletedWords() {
        let before = "Owner Ann ships on Friday."
        let after = "Owner ships on Friday."
        let segments = WordDiff.diff(before: before, after: after)
        XCTAssertEqual(segments, [
            Segment(kind: .same, text: "Owner "),
            Segment(kind: .removed, text: "Ann "),
            Segment(kind: .same, text: "ships on Friday.")
        ])
        assertReconstructs(segments, before: before, after: after)
    }

    func testReplacedWord() {
        let before = "Ships on Friday."
        let after = "Ships on Monday."
        XCTAssertEqual(WordDiff.diff(before: before, after: after), [
            Segment(kind: .same, text: "Ships on "),
            Segment(kind: .removed, text: "Friday."),
            Segment(kind: .added, text: "Monday.")
        ])
    }

    /// Two replaced words separated by one space read as one replaced
    /// phrase, not as four fragments around a lone unchanged space.
    func testAdjacentReplacementsJoinIntoOnePhrase() {
        let before = "Ships on Friday morning."
        let after = "Ships on Monday evening."
        let segments = WordDiff.diff(before: before, after: after)
        XCTAssertEqual(segments, [
            Segment(kind: .same, text: "Ships on "),
            Segment(kind: .removed, text: "Friday morning."),
            Segment(kind: .added, text: "Monday evening.")
        ])
        assertReconstructs(segments, before: before, after: after)
    }

    func testCyrillicAndNonBreakingSpaces() {
        let before = "Владелец\u{00A0}⟦1:@Ann Lee⟧ отгружает в пятницу."
        let after = "Отгружаем в понедельник."
        let segments = WordDiff.diff(before: before, after: after)
        assertReconstructs(segments, before: before, after: after)
        XCTAssertTrue(segments.contains(Segment(kind: .same, text: " в ")))
        XCTAssertTrue(segments.contains(Segment(kind: .removed, text: "пятницу.")))
        XCTAssertTrue(segments.contains(Segment(kind: .added, text: "понедельник.")))
        XCTAssertTrue(segments.contains { $0.kind == .removed && $0.text.contains("⟦1:@Ann Lee⟧") })
    }

    func testWhitespaceChangesArePreserved() {
        let before = "one two\n\nthree"
        let after = "one  two\nthree"
        assertReconstructs(WordDiff.diff(before: before, after: after), before: before, after: after)
    }

    func testEmptySides() {
        XCTAssertEqual(WordDiff.diff(before: "", after: ""), [])
        XCTAssertEqual(WordDiff.diff(before: "", after: "New text"), [Segment(kind: .added, text: "New text")])
        XCTAssertEqual(WordDiff.diff(before: "Old text", after: ""), [Segment(kind: .removed, text: "Old text")])
    }

    /// A rewrite too large for the word table degrades to "all of this
    /// replaced by all of that" — still exact, never slow or unbounded.
    func testHugeRewriteFallsBackToWholeReplacement() {
        let before = (0..<3000).map { "a\($0)" }.joined(separator: " ")
        let after = (0..<3000).map { "b\($0)" }.joined(separator: " ")
        let segments = WordDiff.diff(before: before, after: after)
        XCTAssertEqual(segments, [
            Segment(kind: .removed, text: before),
            Segment(kind: .added, text: after)
        ])
    }

    /// The fallback keeps the unchanged head and tail of a long text: only
    /// the rewritten middle is struck through.
    func testLongTextWithSmallEditKeepsItsContext() {
        let head = (0..<5000).map { "w\($0)" }.joined(separator: " ")
        let before = head + " old tail"
        let after = head + " new tail"
        let segments = WordDiff.diff(before: before, after: after)
        XCTAssertEqual(segments, [
            Segment(kind: .same, text: head + " "),
            Segment(kind: .removed, text: "old"),
            Segment(kind: .added, text: "new"),
            Segment(kind: .same, text: " tail")
        ])
    }
}
