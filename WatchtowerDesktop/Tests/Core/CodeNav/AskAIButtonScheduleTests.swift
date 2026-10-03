import XCTest
@testable import WatchtowerCore

/// The ✦ button (spec 2026-10-02 §9.2): it appears 0.5 s after a non-empty
/// selection settles, and hides while typing (every keystroke moves the
/// selection), on scroll, when the selection clears, and while the popover
/// is open. Driven by an injected clock.
final class AskAIButtonScheduleTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 1_000)

    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    func testAppearsHalfASecondAfterTheSelectionSettles() {
        var schedule = AskAIButtonSchedule()
        schedule.selectionChanged(hasSelection: true, at: at(0))
        XCTAssertEqual(schedule.deadline, at(0.5))
        schedule.tick(at: at(0.49))
        XCTAssertFalse(schedule.isVisible, "not before it settles")
        schedule.tick(at: at(0.5))
        XCTAssertTrue(schedule.isVisible)
        XCTAssertNil(schedule.deadline, "nothing left to wait for")
    }

    /// Typing moves the selection: each change hides the button and the
    /// half second starts again from the last one.
    func testHiddenWhileTyping() {
        var schedule = AskAIButtonSchedule()
        schedule.selectionChanged(hasSelection: true, at: at(0))
        schedule.tick(at: at(0.6))
        XCTAssertTrue(schedule.isVisible)
        for step in 1...5 {
            let now = at(0.6 + Double(step) * 0.2)
            schedule.selectionChanged(hasSelection: true, at: now)
            XCTAssertFalse(schedule.isVisible, "hidden at keystroke \(step)")
            schedule.tick(at: now.addingTimeInterval(0.19))
            XCTAssertFalse(schedule.isVisible, "still hidden between keystrokes")
        }
        schedule.tick(at: at(1.6 + 0.5))
        XCTAssertTrue(schedule.isVisible, "back once typing stops for half a second")
    }

    func testHiddenOnScrollAndBackAfterItSettles() {
        var schedule = AskAIButtonSchedule()
        schedule.selectionChanged(hasSelection: true, at: at(0))
        schedule.tick(at: at(0.5))
        schedule.scrolled(at: at(1))
        XCTAssertFalse(schedule.isVisible)
        XCTAssertEqual(schedule.deadline, at(1.5))
        schedule.tick(at: at(1.5))
        XCTAssertTrue(schedule.isVisible)
    }

    func testHiddenWhenTheSelectionClears() {
        var schedule = AskAIButtonSchedule()
        schedule.selectionChanged(hasSelection: true, at: at(0))
        schedule.tick(at: at(0.5))
        schedule.selectionChanged(hasSelection: false, at: at(1))
        XCTAssertFalse(schedule.isVisible)
        XCTAssertNil(schedule.deadline, "no selection, nothing to show")
        schedule.tick(at: at(5))
        XCTAssertFalse(schedule.isVisible)
        schedule.scrolled(at: at(6))
        schedule.tick(at: at(7))
        XCTAssertFalse(schedule.isVisible, "a scroll never shows it without a selection")
    }

    /// The popover replaces the button; after it closes the button comes
    /// back for a selection that is still there, after the usual pause.
    func testSuppressedWhileThePopoverIsOpen() {
        var schedule = AskAIButtonSchedule()
        schedule.selectionChanged(hasSelection: true, at: at(0))
        schedule.tick(at: at(0.5))
        schedule.suppress()
        XCTAssertFalse(schedule.isVisible)
        schedule.selectionChanged(hasSelection: true, at: at(1))
        schedule.tick(at: at(3))
        XCTAssertFalse(schedule.isVisible)
        XCTAssertNil(schedule.deadline)
        schedule.resume(at: at(4))
        XCTAssertEqual(schedule.deadline, at(4.5))
        schedule.tick(at: at(4.5))
        XCTAssertTrue(schedule.isVisible)
    }
}
