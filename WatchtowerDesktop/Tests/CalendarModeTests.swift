import XCTest
@testable import WatchtowerDesktop

final class CalendarModeTests: XCTestCase {
    func test_modesInOrder() {
        XCTAssertEqual(CalendarMode.allCases.map(\.rawValue), ["events", "recordings"])
    }

    func test_titles() {
        XCTAssertEqual(CalendarMode.events.title, "Events")
        XCTAssertEqual(CalendarMode.recordings.title, "Recordings")
    }
}
