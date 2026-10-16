import XCTest
@testable import WatchtowerCore

final class AutomationsPollPolicyTests: XCTestCase {
    func testIntervals() {
        XCTAssertEqual(AutomationsPollPolicy.interval(hasActiveRuns: true, tabVisible: false), .seconds(2))
        XCTAssertEqual(AutomationsPollPolicy.interval(hasActiveRuns: true, tabVisible: true), .seconds(2))
        XCTAssertEqual(AutomationsPollPolicy.interval(hasActiveRuns: false, tabVisible: true), .seconds(10))
        XCTAssertEqual(AutomationsPollPolicy.interval(hasActiveRuns: false, tabVisible: false), .seconds(60))
    }
}
