import XCTest
@testable import WatchtowerCore

/// Open Quickly's fzf-style matcher (spec §7): word starts, camelCase humps,
/// path separators and consecutive runs score; case is smart.
final class FuzzyMatchTests: XCTestCase {
    func testHumpsBeatInnerLetters() throws {
        let hump = try XCTUnwrap(FuzzyMatch.score(query: "cfbuf", candidate: "CodeFileBuffer"))
        let inner = try XCTUnwrap(FuzzyMatch.score(query: "cfbuf", candidate: "ConfigBuffer"))
        XCTAssertGreaterThan(hump.score, inner.score)
        XCTAssertEqual(hump.matched, [0, 4, 8, 9, 10])
    }

    func testPathQueryCrossesFolders() throws {
        let hit = try XCTUnwrap(FuzzyMatch.score(query: "vm/cfb", candidate: "ViewModels/CodeFileBuffer.swift"))
        XCTAssertEqual(hit.matched, [0, 4, 10, 11, 15, 19])
    }

    func testNoSubsequenceIsNil() {
        XCTAssertNil(FuzzyMatch.score(query: "xyz", candidate: "CodeFileBuffer"))
        XCTAssertNil(FuzzyMatch.score(query: "bufferx", candidate: "Buffer"))
    }

    func testEmptyQueryMatchesEverythingWithNothingMarked() throws {
        let hit = try XCTUnwrap(FuzzyMatch.score(query: "", candidate: "anything"))
        XCTAssertEqual(hit.score, 0)
        XCTAssertEqual(hit.matched, [])
    }

    func testSmartCase() {
        XCTAssertNotNil(FuzzyMatch.score(query: "cfb", candidate: "CodeFileBuffer"))
        XCTAssertNotNil(FuzzyMatch.score(query: "cfb", candidate: "codefilebuffer"))
        XCTAssertNotNil(FuzzyMatch.score(query: "CFB", candidate: "CodeFileBuffer"))
        XCTAssertNil(FuzzyMatch.score(query: "CFB", candidate: "codefilebuffer"))
        XCTAssertNil(FuzzyMatch.score(query: "cFb", candidate: "CodeFileBuffer"), "an upper-case letter makes every letter exact")
    }

    func testConsecutiveRunBeatsScatteredLetters() throws {
        let hit = try XCTUnwrap(FuzzyMatch.score(query: "buf", candidate: "CodeFileBuffer"))
        XCTAssertEqual(hit.matched, [8, 9, 10])
    }

    func testWordStartAfterDelimiter() throws {
        let hit = try XCTUnwrap(FuzzyMatch.score(query: "sn", candidate: "is_save_now"))
        XCTAssertEqual(hit.matched, [3, 8])
    }

    func testExactNameBeatsLongerName() throws {
        let exact = try XCTUnwrap(FuzzyMatch.score(query: "buffer", candidate: "Buffer"))
        let longer = try XCTUnwrap(FuzzyMatch.score(query: "buffer", candidate: "BufferPoolAllocator"))
        XCTAssertGreaterThan(exact.score, longer.score)
    }

    /// Offsets are UTF-16 units: what NSString/AttributedString ranges need.
    func testNonASCIIOffsetsAreUTF16() throws {
        let hit = try XCTUnwrap(FuzzyMatch.score(query: "nf", candidate: "😀naïveFunc"))
        XCTAssertEqual(hit.matched, [2, 7])
        XCTAssertNotNil(FuzzyMatch.score(query: "пр", candidate: "привет"))
    }
}
