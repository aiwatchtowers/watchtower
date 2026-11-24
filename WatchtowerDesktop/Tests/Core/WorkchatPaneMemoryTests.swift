import XCTest
@testable import WatchtowerCore

/// The per-pane, in-memory toggles of the Workchat 👥 list (#2065 spec §2):
/// the default until the owner toggles, then the owner's choice.
@MainActor
final class WorkchatPaneMemoryTests: XCTestCase {
    func testDoneDefaultUntilOwnerToggles() {
        let memory = WorkchatPaneMemory()
        XCTAssertTrue(memory.doneOpen("p", default: true))
        XCTAssertFalse(memory.doneOpen("p", default: false))
        memory.setDoneOpen("p", false)
        XCTAssertFalse(memory.doneOpen("p", default: true), "the owner's toggle wins over the default")
        memory.setDoneOpen("p", true)
        XCTAssertTrue(memory.doneOpen("p", default: false))
    }

    func testStepsClosedByDefault() {
        let memory = WorkchatPaneMemory()
        XCTAssertFalse(memory.stepsOpen("p"), "the steps list is closed by default (#2201 §1)")
        memory.toggleSteps("p")
        XCTAssertTrue(memory.stepsOpen("p"))
        XCTAssertFalse(memory.stepsOpen("q"), "another pane keeps the default")
        memory.toggleSteps("p")
        XCTAssertFalse(memory.stepsOpen("p"))
    }

    func testPanesAreIndependent() {
        let memory = WorkchatPaneMemory()
        memory.setDoneOpen("session-1", true)
        XCTAssertTrue(memory.doneOpen("session-1", default: false))
        XCTAssertFalse(memory.doneOpen("session-2", default: false))
        XCTAssertFalse(memory.doneOpen("session-1/tu1", default: false), "a subagent screen is its own pane")
    }
}
