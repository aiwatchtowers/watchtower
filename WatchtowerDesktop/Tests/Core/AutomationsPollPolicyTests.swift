import XCTest
@testable import WatchtowerCore

final class AutomationsPollPolicyTests: XCTestCase {
    func testIntervals() {
        XCTAssertEqual(AutomationsPollPolicy.interval(hasActiveRuns: true, hasWatchedRuns: false, tabVisible: false),
                       .seconds(2))
        XCTAssertEqual(AutomationsPollPolicy.interval(hasActiveRuns: true, hasWatchedRuns: false, tabVisible: true),
                       .seconds(2))
        XCTAssertEqual(AutomationsPollPolicy.interval(hasActiveRuns: false, hasWatchedRuns: false, tabVisible: true),
                       .seconds(10))
        XCTAssertEqual(AutomationsPollPolicy.interval(hasActiveRuns: false, hasWatchedRuns: false, tabVisible: false),
                       .seconds(60))
    }

    /// A run started from the palette or the tray is watched for its finish
    /// notice: the poll stays fast with the tab hidden.
    func testWatchedRunsPollFast() {
        XCTAssertEqual(AutomationsPollPolicy.interval(hasActiveRuns: false, hasWatchedRuns: true, tabVisible: false),
                       .seconds(2))
        XCTAssertEqual(AutomationsPollPolicy.interval(hasActiveRuns: false, hasWatchedRuns: true, tabVisible: true),
                       .seconds(2))
    }

    /// Nothing watched: the Task 6 cadence again.
    func testBackToNormalWhenNothingWatched() {
        XCTAssertEqual(AutomationsPollPolicy.interval(hasActiveRuns: false, hasWatchedRuns: false, tabVisible: false),
                       .seconds(60))
        XCTAssertEqual(AutomationsPollPolicy.interval(hasActiveRuns: false, hasWatchedRuns: false, tabVisible: true),
                       .seconds(10))
        XCTAssertEqual(AutomationsPollPolicy.interval(hasActiveRuns: true, hasWatchedRuns: false, tabVisible: false),
                       .seconds(2))
    }
}
