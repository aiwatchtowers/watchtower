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

    // MARK: locate — performance (the collapsed-text path must stay near-linear)

    /// A regression guard against reintroducing the pre-fix collapsed-text
    /// search (a hand-rolled Character-array scan), not a tight performance
    /// budget.
    ///
    /// The bound is relative to the machine: `locate` must cost under
    /// `maxBaselineMultiple` times one linear pass over the same document that
    /// collapses its whitespace into a new String — work `locate` itself does
    /// once. CI runners are noisy and also consistently slower than a laptop,
    /// so a fixed wall-clock bound flaked (0.50–0.78 s against 0.5 s); a slow
    /// runner slows both sides of the ratio alike. Each side is the fastest of
    /// three runs on a monotonic clock, since noise only ever adds time.
    /// Measured locally only (debug build): the current `locate` runs at
    /// 1.95–1.99× the baseline idle and up to 2.4× with every core saturated;
    /// the pre-fix scan at 4.71–4.86×. The bound of 3.4 is the geometric mean
    /// of the worst current reading under load and the best pre-fix one
    /// (√(2.4 × 4.71) ≈ 3.36), about 1.4× clear of each. (A 1 MB vs 2 MB
    /// scaling check would not catch the old scan: with the quote length
    /// fixed, O(n·m) also grows linearly in n.) The absolute 5 s ceiling is
    /// only a backstop far above any CI reading.
    func testReflowMatchOnLargeDocumentCompletesQuickly() throws {
        let paragraph = "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore.\n\n"
        let padding = String(repeating: paragraph, count: 8_000) // ~1 MB, contains no copy of the quote below.
        let quote = "jumps over the lazy dog near the riverbank"
        let made = try anchor(quote, in: "The quick brown fox " + quote + " at dawn.")

        // The reflowed occurrence (line break + double space inside the quote) never matches
        // exactly, so `locate` must fall through to the collapsed-text search path.
        let reflowedQuote = "jumps over the\n  lazy dog near the riverbank"
        let reflowedSentence = "The quick brown fox " + reflowedQuote + " at dawn."
        let insertAt = padding.index(padding.startIndex, offsetBy: padding.count / 2)
        let big = String(padding[..<insertAt]) + reflowedSentence + String(padding[insertAt...])

        var found: Range<String.Index>?
        let locateTime = Self.fastestOfThree { found = made.locate(in: big) }
        var collapsed = "" // counted outside the timing: only the collapse pass is measured
        let baselineTime = Self.fastestOfThree {
            var out = ""
            var lastWasSpace = false
            for character in big {
                if character.isWhitespace {
                    if !lastWasSpace { out.append(" ") }
                    lastWasSpace = true
                } else {
                    out.append(character)
                    lastWasSpace = false
                }
            }
            collapsed = out
        }
        XCTAssertGreaterThan(collapsed.count, 0)

        let maxBaselineMultiple = 3.4
        let ratio = locateTime / max(baselineTime, 1e-6)
        XCTAssertLessThan(
            ratio, maxBaselineMultiple,
            "reflow locate took \(locateTime)s, \(ratio)× a linear pass over the same ~1 MB document (\(baselineTime)s)"
        )
        XCTAssertLessThan(locateTime, 5, "reflow locate on a ~1 MB document took \(locateTime)s")
        XCTAssertEqual(found.map { String(big[$0]) }, reflowedQuote)
    }

    /// Seconds taken by the fastest of three runs of `body`.
    private static func fastestOfThree(_ body: () -> Void) -> Double {
        let clock = ContinuousClock()
        var fastest = Duration.seconds(Int64.max)
        for _ in 0..<3 {
            let start = clock.now
            body()
            fastest = min(fastest, clock.now - start)
        }
        return Double(fastest.components.seconds) + Double(fastest.components.attoseconds) / 1e18
    }

    /// Boundary check on the collapsed-text path itself: a match whose first
    /// or last character sits at the very edge of the searched text exercises
    /// the `position`/`origins` bookkeeping at both ends.
    func testCollapsedMatchAtStartAndEndOfTextBoundaries() throws {
        let made = try anchor("open the gate now", in: "open the gate now, then relax.")

        let reflowedStart = "open   the\ngate now"
        let startText = reflowedStart + ", then relax further into the evening."
        let foundStart = made.locate(in: startText)
        XCTAssertEqual(foundStart.map { String(startText[$0]) }, reflowedStart)
        XCTAssertEqual(foundStart?.lowerBound, startText.startIndex)

        let reflowedEnd = "open  the gate\nnow"
        let endText = "Some preface before the payload arrives.  " + reflowedEnd
        let foundEnd = made.locate(in: endText)
        XCTAssertEqual(foundEnd.map { String(endText[$0]) }, reflowedEnd)
        XCTAssertEqual(foundEnd?.upperBound, endText.endIndex)
    }

    // MARK: legacy renderings (#181)

    /// Comments made before tables and rules got their own layout keep
    /// their place: the old " | " cell joins, a table artifact's raw CSV and
    /// the "———" rule read as the line breaks the new rendering puts there.
    func testQuotesFromTheOldTableAndRuleRenderingStillLocate() throws {
        let markdown = "| Name | Owner |\n|---|---|\n| retry | ops |\n\n---\n\nAfter the rule."
        let old = "Name | Owner\nretry | ops\n\n———\n\nAfter the rule.\n\n"
        let new = DocumentRendering.render(markdown).text
        let row = try anchor("retry | ops", in: old)
        XCTAssertEqual(row.locate(in: new).map { String(new[$0]) }, "retry\nops")
        let rule = try anchor("———\n\nAfter", in: old)
        XCTAssertNotNil(rule.locate(in: new))

        let csv = try anchor("retry,ops", in: "Name,Owner\nretry,ops")
        let table = DocumentRendering.renderTable(rows: [["Name", "Owner"], ["retry", "ops"]]).text
        XCTAssertEqual(csv.locate(in: table, csv: true).map { String(table[$0]) }, "retry\nops")
        XCTAssertNil(csv.locate(in: table), "only a table artifact's anchor was CSV")
    }

    /// PROJ-03: a quote that is gone never lands on look-alike text elsewhere.
    func testTheLegacyTierNeedsTheOriginalContext() throws {
        let made = try anchor("x | y", in: "Name | Owner\nx | y\n\nMore text here.")
        XCTAssertNil(made.locate(in: "A different document.\n\nx\ny\n\nUnrelated ending."))
        let prose = try anchor("alice,bob", in: "Ping alice,bob today.")
        XCTAssertNil(prose.locate(in: "Ping someone today. Then alice\nbob."), "commas are CSV only in a table artifact")
    }
}
