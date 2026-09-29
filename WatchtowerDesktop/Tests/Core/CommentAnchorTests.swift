import XCTest
@testable import WatchtowerCore

final class CommentAnchorTests: XCTestCase {
    private func range(of needle: String, in text: String, occurrence: Int = 0) throws -> Range<String.Index> {
        var start = text.startIndex
        var found: Range<String.Index>?
        for _ in 0...occurrence {
            found = text.range(of: needle, range: start..<text.endIndex)
            start = found.map { text.index(after: $0.lowerBound) } ?? text.endIndex
        }
        return try XCTUnwrap(found)
    }

    private func anchor(
        _ needle: String,
        in text: String,
        occurrence: Int = 0,
        headings: [(offset: Int, title: String)] = []
    ) throws -> CommentAnchor {
        CommentAnchor.make(text: text, range: try range(of: needle, in: text, occurrence: occurrence), headings: headings)
    }

    // MARK: make

    func testMakeTakesQuoteBoundedContextAndNearestPrecedingHeading() throws {
        let text = "Intro\n\nErrors\n\nRetry the call twice before giving up.\n\nLater\n\nMore."
        let later = (text as NSString).range(of: "Later").location
        let errors = (text as NSString).range(of: "Errors").location
        let made = try anchor("the call twice", in: text, headings: [(0, "Intro"), (errors, "Errors"), (later, "Later")])
        XCTAssertEqual(made.quote, "the call twice")
        XCTAssertEqual(made.prefix, "Intro\n\nErrors\n\nRetry ")
        XCTAssertEqual(made.suffix, " before giving up.\n\nLater\n\nMore.")
        XCTAssertEqual(made.heading, "Errors")
    }

    func testMakeCapsContextAtSixtyFourCharacters() throws {
        let text = String(repeating: "a", count: 100) + "QUOTE" + String(repeating: "b", count: 100)
        let made = try anchor("QUOTE", in: text)
        XCTAssertEqual(made.prefix.count, CommentAnchor.contextLength)
        XCTAssertEqual(made.suffix.count, CommentAnchor.contextLength)
        XCTAssertEqual(made.heading, "")
    }

    // MARK: locate — the easy cases

    func testUniqueQuoteIsFoundAgainAfterTextIsInsertedAbove() throws {
        let original = "Keep the retry budget small.\n\nSomething else."
        let made = try anchor("retry budget", in: original)
        let revised = "A brand new first paragraph.\n\n" + original
        let found = made.locate(in: revised)
        XCTAssertEqual(found.map { String(revised[$0]) }, "retry budget")
        XCTAssertEqual(found?.lowerBound, try range(of: "retry budget", in: revised).lowerBound)
    }

    func testEmptyQuoteNeverLocates() throws {
        XCTAssertNil(CommentAnchor(quote: "", prefix: "a", suffix: "b", heading: "").locate(in: "a b"))
        XCTAssertNil(CommentAnchor(quote: "  \n", prefix: "", suffix: "", heading: "").locate(in: "a  \n b"))
    }

    // MARK: locate — Review Focus #4

    func testDuplicateQuotePicksTheOccurrenceWithTheBestContext() throws {
        let text = "Step one: retry the call. Then log it.\n\nStep two: check the queue, retry the call, and alert."
        let made = try anchor("retry the call", in: text, occurrence: 1)
        let found = made.locate(in: text)
        XCTAssertEqual(found?.lowerBound, try range(of: "retry the call", in: text, occurrence: 1).lowerBound)
    }

    func testDuplicateQuoteSurvivesTextInsertedAboveIt() throws {
        let text = "Step one: retry the call. Then log it.\n\nStep two: check the queue, retry the call, and alert."
        let made = try anchor("retry the call", in: text, occurrence: 1)
        let revised = "New preface that mentions nothing.\n\n" + text.replacingOccurrences(of: "Then log it.", with: "Then log it twice.")
        let found = made.locate(in: revised)
        XCTAssertEqual(found?.lowerBound, try range(of: "retry the call", in: revised, occurrence: 1).lowerBound)
    }

    func testDuplicatesWithNoMatchingContextAreOutdated() throws {
        let made = try anchor("retry the call", in: "alpha:retry the call;omega")
        // Both surviving copies have none of the original context around them:
        // the anchored passage was rewritten — refusing beats guessing.
        XCTAssertNil(made.locate(in: "1retry the call2 3retry the call4"))
    }

    func testSingleSurvivingCopyWinsEvenWithDifferentContext() throws {
        let made = try anchor("retry the call", in: "alpha:retry the call;omega")
        let revised = "The plan: retry the call once."
        XCTAssertEqual(made.locate(in: revised).map { String(revised[$0]) }, "retry the call")
    }

    func testWhitespaceReflowStillLocates() throws {
        let original = "Keep the retry budget small so a flaky service cannot stall the sync."
        let made = try anchor("retry budget small so a flaky", in: original)
        let reflowed = "Keep the retry\n  budget small so a\nflaky service cannot stall the sync."
        let found = made.locate(in: reflowed)
        XCTAssertEqual(found.map { String(reflowed[$0]) }, "retry\n  budget small so a\nflaky")
    }

    func testReflowWithDuplicatesStillUsesContext() throws {
        let original = "First: stop the sync now. Second: when idle, stop the sync now, then report."
        let made = try anchor("stop the sync now", in: original, occurrence: 1)
        let reflowed = "First: stop the\nsync now. Second: when idle, stop  the sync\nnow, then report."
        let found = made.locate(in: reflowed)
        XCTAssertEqual(found.map { String(reflowed[$0]) }, "stop  the sync\nnow")
    }

    func testDeletedPassageIsOutdated() throws {
        let made = try anchor("retry budget", in: "Keep the retry budget small.\n\nOther text.")
        XCTAssertNil(made.locate(in: "Other text.\n\nA new ending."))
    }

    func testEditedQuoteIsOutdatedNotFuzzyMatched() throws {
        let made = try anchor("retry budget small", in: "Keep the retry budget small.")
        XCTAssertNil(made.locate(in: "Keep the retry budget tiny."))
    }

    func testNonASCIITextRoundTrips() throws {
        let text = "Вступ\n\nПовтори виклик 🔁 двічі.\n\nКінець."
        let made = try anchor("виклик 🔁 двічі", in: text)
        XCTAssertEqual(made.locate(in: "Новий абзац.\n\n" + text).map { String(("Новий абзац.\n\n" + text)[$0]) }, "виклик 🔁 двічі")
    }
}
