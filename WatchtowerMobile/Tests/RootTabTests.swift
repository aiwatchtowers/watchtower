import XCTest
@testable import WatchtowerMobile

/// The phone's tab bar (mobile POC spec §13 A4): Now, Workbench, Calendar,
/// More, in that order, with Settings reached only through More.
final class RootTabTests: XCTestCase {
    func testExactlyFourTabsInOrder() {
        XCTAssertEqual(
            RootTabView.Tab.allCases.map(\.title),
            ["Now", "Workbench", "Calendar", "More"]
        )
    }

    func testMoreHoldsSettingsOnly() {
        XCTAssertEqual(MoreView.Row.allCases.map(\.title), ["Settings"])
    }

    /// Spec §3: the foreground fetch runs every 5 s while Now or Workbench
    /// is on screen and every 30 s otherwise.
    func testForegroundFetchIsFastOnNowAndWorkbenchOnly() {
        XCTAssertEqual(RootTabView.Tab.now.fetchInterval, .seconds(5))
        XCTAssertEqual(RootTabView.Tab.workbench.fetchInterval, .seconds(5))
        XCTAssertEqual(RootTabView.Tab.calendar.fetchInterval, .seconds(30))
        XCTAssertEqual(RootTabView.Tab.more.fetchInterval, .seconds(30))
    }
}
