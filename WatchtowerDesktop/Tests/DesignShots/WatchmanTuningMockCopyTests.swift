import XCTest
@testable import WatchtowerDesktop

/// Pins the Watchman tuning spec's mock strings (#2134) to the spec's text, so
/// the mockups and `docs/superpowers/specs/2026-11-21-watchman-tuning-design.md`
/// cannot drift apart.
final class WatchmanTuningMockCopyTests: XCTestCase {
    typealias Copy = WatchmanTuningMockCopy

    func testStringsMatchTheSpec() {
        XCTAssertEqual(Copy.icon, "binoculars")
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
    }
}
