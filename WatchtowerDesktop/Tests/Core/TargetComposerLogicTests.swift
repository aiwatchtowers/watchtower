import XCTest
@testable import WatchtowerCore

final class TargetComposerLogicTests: XCTestCase {
    func testSingleLineTextIsItsOwnTitle() {
        XCTAssertEqual(
            TargetComposerLogic.deriveTitle(from: "Ship the release"),
            "Ship the release"
        )
    }

    func testFirstLineOfMultilineText() {
        let text = "Ship the release\nWalk the transcripts\nGather Jira data"
        XCTAssertEqual(TargetComposerLogic.deriveTitle(from: text), "Ship the release")
    }

    func testLeadingBlankLinesAreSkipped() {
        let text = "\n\n   \nShip the release\nmore context"
        XCTAssertEqual(TargetComposerLogic.deriveTitle(from: text), "Ship the release")
    }

    func testFirstLineIsTrimmed() {
        XCTAssertEqual(
            TargetComposerLogic.deriveTitle(from: "   Ship the release  \nrest"),
            "Ship the release"
        )
    }

    func testEmptyAndWhitespaceOnlyTextYieldEmptyTitle() {
        XCTAssertEqual(TargetComposerLogic.deriveTitle(from: ""), "")
        XCTAssertEqual(TargetComposerLogic.deriveTitle(from: "  \n\t\n  "), "")
    }

    func testLineAtExactCapIsNotTruncated() {
        let line = String(repeating: "abcde ", count: 20)
            .trimmingCharacters(in: .whitespaces)  // 119 chars
        XCTAssertLessThanOrEqual(line.count, TargetComposerLogic.titleCap)
        XCTAssertEqual(TargetComposerLogic.deriveTitle(from: line), line)
    }

    func testLongLineIsCappedOnAWordBoundary() {
        let line = String(repeating: "word ", count: 40)
            .trimmingCharacters(in: .whitespaces)  // 199 chars
        let title = TargetComposerLogic.deriveTitle(from: line)
        XCTAssertTrue(title.hasSuffix("…"))
        XCTAssertLessThanOrEqual(title.count, TargetComposerLogic.titleCap + 1)
        // The cut lands on a word boundary: dropping the ellipsis leaves a
        // prefix of the line whose next character in the line is a space.
        let base = String(title.dropLast())
        XCTAssertFalse(base.hasSuffix(" "))
        XCTAssertTrue(line.hasPrefix(base + " "))
    }

    func testUnbrokenTokenFallsBackToHardCut() {
        let line = String(repeating: "x", count: 200)
        let title = TargetComposerLogic.deriveTitle(from: line)
        XCTAssertEqual(title, String(repeating: "x", count: TargetComposerLogic.titleCap) + "…")
    }
}
