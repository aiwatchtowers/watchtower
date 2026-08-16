import XCTest
@testable import WatchtowerDesktop

/// Pure volatile/final accumulation behind the Apple streaming lane
/// (realtime-dictation plan Task 3): finalized pieces accumulate
/// space-joined; a volatile piece only ever REPLACES the tail. No
/// Speech.framework anywhere near this — the analyzer internals are
/// deliberately not unit-tested, the accumulator is.
final class AppleDictationAccumulatorTests: XCTestCase {

    func testFinalPieceBecomesTheDisplay() {
        var acc = AppleDictationAccumulator()
        acc.accept(text: "hello", isFinal: true)
        XCTAssertEqual(acc.display, "hello")
        XCTAssertEqual(acc.finalized, "hello")
        XCTAssertEqual(acc.volatileTail, "")
    }

    func testVolatileTailAppendsToFinalizedInDisplay() {
        var acc = AppleDictationAccumulator()
        acc.accept(text: "hello", isFinal: true)
        acc.accept(text: "wor", isFinal: false)
        XCTAssertEqual(acc.display, "hello wor")
        XCTAssertEqual(acc.finalized, "hello", "a volatile piece must never touch the finalized prefix")
    }

    func testVolatileReplacesTheTailNotAppends() {
        var acc = AppleDictationAccumulator()
        acc.accept(text: "hello", isFinal: true)
        acc.accept(text: "wor", isFinal: false)
        acc.accept(text: "world", isFinal: false)
        XCTAssertEqual(acc.display, "hello world", "a refined volatile piece REPLACES the tail wholesale")
        XCTAssertEqual(acc.volatileTail, "world")
    }

    func testFinalAbsorbsTheVolatileTail() {
        var acc = AppleDictationAccumulator()
        acc.accept(text: "hello", isFinal: true)
        acc.accept(text: "wor", isFinal: false)
        acc.accept(text: "world", isFinal: false)
        acc.accept(text: "world", isFinal: true)
        XCTAssertEqual(acc.finalized, "hello world")
        XCTAssertEqual(acc.volatileTail, "", "a finalized piece clears the volatile tail")
        XCTAssertEqual(acc.display, "hello world", "the display must not change when the tail finalizes as-is")
    }

    func testVolatileOnlyFromStart() {
        var acc = AppleDictationAccumulator()
        acc.accept(text: "hi", isFinal: false)
        XCTAssertEqual(acc.display, "hi")
        XCTAssertEqual(acc.finalized, "", "nothing is finalized by a volatile piece")
    }

    func testEmptyPiecesAreIgnoredForBothFlags() {
        var acc = AppleDictationAccumulator()
        acc.accept(text: "hello", isFinal: true)
        acc.accept(text: "wor", isFinal: false)

        acc.accept(text: "", isFinal: false)
        XCTAssertEqual(acc.display, "hello wor", "an empty volatile piece must not wipe the visible tail")

        acc.accept(text: "", isFinal: true)
        XCTAssertEqual(acc.finalized, "hello", "an empty final piece has nothing to accumulate")
        XCTAssertEqual(acc.display, "hello wor")
    }

    /// A sequence ending on a volatile piece the framework never finalizes:
    /// `display` retains it — this pins the value `AppleDictationSession`
    /// returns, so text the user watched on screen is never silently dropped.
    func testDisplayRetainsANeverFinalizedTrailingVolatileTail() {
        var acc = AppleDictationAccumulator()
        acc.accept(text: "hello", isFinal: true)
        acc.accept(text: "trailing tail", isFinal: false)
        XCTAssertEqual(acc.display, "hello trailing tail",
                       "a never-finalized volatile tail must stay in the display — everything shown is delivered")
        XCTAssertEqual(acc.finalized, "hello")
    }

    func testFinalAfterFinalSpaceJoins() {
        var acc = AppleDictationAccumulator()
        acc.accept(text: "hello", isFinal: true)
        acc.accept(text: "world", isFinal: true)
        XCTAssertEqual(acc.finalized, "hello world")
        XCTAssertEqual(acc.display, "hello world")
    }
}
