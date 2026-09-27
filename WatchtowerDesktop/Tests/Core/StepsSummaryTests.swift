import XCTest
@testable import WatchtowerCore

final class StepsSummaryTests: XCTestCase {
    func testHeader() {
        XCTAssertEqual(StepsSummary.header(stepCount: 4, elapsed: 12.2, running: false), "Worked for 12s · 4 steps")
        XCTAssertEqual(StepsSummary.header(stepCount: 1, elapsed: 65, running: false), "Worked for 1m 05s · 1 step")
        XCTAssertEqual(StepsSummary.header(stepCount: 2, elapsed: 3, running: true), "Working… · 2 steps")
    }

    func testElapsedSpansFirstStartToLastEnd() {
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        let steps = [
            ChatStepDisplay(id: "a", name: "x", argsJSON: "{}", state: .succeeded, summary: "", sources: [],
                            startedAt: t0, endedAt: t0.addingTimeInterval(3)),
            ChatStepDisplay(id: "b", name: "y", argsJSON: "{}", state: .running, summary: "", sources: [],
                            startedAt: t0.addingTimeInterval(4), endedAt: nil)
        ]
        XCTAssertEqual(StepsSummary.elapsed(steps: steps, running: true, now: t0.addingTimeInterval(10)), 10)
        XCTAssertEqual(StepsSummary.elapsed(steps: steps, running: false, now: t0.addingTimeInterval(99)), 3)
        XCTAssertEqual(StepsSummary.elapsed(steps: [], running: false, now: t0), 0)
    }
}
