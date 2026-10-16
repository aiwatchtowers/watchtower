import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore

final class EmptyStateCopyCoverageTests: XCTestCase {
    func testEverySidebarDestinationHasCopyOrIsExempt() {
        for destination in SidebarDestination.allCases {
            let copy = EmptyStateCopyTable.copy(for: destination.rawValue, briefingHour: 8, dayPlanHour: 8)
            let exempt = EmptyStateCopyTable.exempt.contains(destination.rawValue)
            XCTAssertTrue((copy != nil) != exempt, "\(destination.rawValue): copy XOR exempt")
            // The empty state shows the tab's own sidebar symbol.
            if let copy { XCTAssertEqual(copy.icon, destination.icon, destination.rawValue) }
        }
    }

    func testExemptListIsExactlyTheSpecs() {
        XCTAssertEqual(EmptyStateCopyTable.exempt, ["search", "usage", "mcpServer", "chat", "home"])
    }
}
