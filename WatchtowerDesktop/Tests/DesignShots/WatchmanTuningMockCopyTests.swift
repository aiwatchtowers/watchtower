import XCTest
import WatchtowerCore
@testable import WatchtowerDesktop

/// Pins the Watchman tuning spec's mock strings (#2134) to the spec's text, so
/// the mockups and `docs/superpowers/specs/2026-11-21-watchman-tuning-design.md`
/// cannot drift apart.
final class WatchmanTuningMockCopyTests: XCTestCase {
    typealias Copy = WatchmanTuningMockCopy

    func testStringsMatchTheSpec() {
        XCTAssertEqual(Copy.icon, "shield.lefthalf.filled")
        XCTAssertEqual(Copy.fieldLabel, "Instruction for Watchman (optional)")
        XCTAssertEqual(Copy.editTitle, "Instruction for Watchman")
        XCTAssertEqual(Copy.handOver, "Hand over")
        XCTAssertEqual(Copy.instructionButton, "Instruction…")
        XCTAssertEqual(Copy.stripLearning, "Watchman · learning 42%")
        XCTAssertEqual(Copy.waitingLearning, "Waiting for learning (42%): 3 questions")
        XCTAssertEqual(Copy.stallReason, "The agent stopped and did not go on after 3 pings")
        XCTAssertTrue(Copy.saveFailed.hasPrefix("Could not save: "))
        XCTAssertTrue(Copy.learningLine.contains("Questions asked meanwhile wait and are decided once it finishes"))
        XCTAssertEqual(Copy.counter(1912), "1912 / 2000")
        XCTAssertEqual(Copy.trayHeader(8), "Hands over 8 sessions:")
    }

    /// The instruction sheet is built (Task 2b): its real copy is the spec's.
    func testImplementedCopyMatchesTheMock() {
        typealias Real = WatchmanArmingCopy
        XCTAssertEqual(Real.shortTitle, Copy.sheetTitle)
        XCTAssertEqual(Real.editTitle, Copy.editTitle)
        XCTAssertEqual(Real.fieldLabel, Copy.fieldLabel)
        XCTAssertEqual(Real.placeholder, Copy.placeholder)
        XCTAssertEqual(Real.handOver, Copy.handOver)
        XCTAssertEqual(Real.save, Copy.save)
        XCTAssertEqual(Real.cancel, Copy.cancel)
        XCTAssertEqual(Real.instructionButton, Copy.instructionButton)
        XCTAssertEqual(Real.saveFailed(Copy.saveFailedReason), Copy.saveFailed)
        XCTAssertEqual(Real.counter(1912), Copy.counter(1912))
        XCTAssertEqual(Real.stripArmed(since: nil), "Watchman · on")
        // The real line groups digits as the history line beside it does.
        XCTAssertEqual(Real.learningLine(WatchmanEstimate(decisions: 1850, needLabels: 0, tokens: 0)),
                       Copy.learningLine.replacingOccurrences(of: "1,850", with: "1 850"))
    }
}
