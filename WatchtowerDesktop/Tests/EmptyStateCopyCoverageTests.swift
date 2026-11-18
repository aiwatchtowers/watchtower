import SwiftUI
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore

final class EmptyStateCopyCoverageTests: XCTestCase {
    func testEverySidebarDestinationHasCopyOrIsExempt() {
        for destination in SidebarDestination.allCases {
            let copy = EmptyStateCopyTable.copy(for: destination.rawValue, briefingHour: 8)
            let exempt = EmptyStateCopyTable.exempt.contains(destination.rawValue)
            XCTAssertTrue((copy != nil) != exempt, "\(destination.rawValue): copy XOR exempt")
            // The empty state shows the tab's own sidebar symbol.
            if let copy { XCTAssertEqual(copy.icon, destination.icon, destination.rawValue) }
        }
    }

    func testExemptListIsExactlyTheSpecs() {
        XCTAssertEqual(EmptyStateCopyTable.exempt, ["usage", "mcpServer", "chat", "home", "connections"])
    }

    /// Slack Live only (screens spec §2.1, §2.2): every tab whose feature
    /// reads Slack, or any source, has the line and the one Connect
    /// workspace app button; Catch-Up and Statistics are among them.
    func testNeedsFullSlackLineOnEverySlackTab() {
        var tabs: [String] = []
        for destination in SidebarDestination.allCases {
            guard let copy = EmptyStateCopyTable.copy(for: destination.rawValue, briefingHour: 8),
                  let feature = copy.feature, feature.source == .slack || feature.source == .anySource
            else { continue }
            tabs.append(destination.rawValue)
            XCTAssertEqual(FeatureEmptyState<EmptyView>.readinessLine(.needsFullSlack),
                           "Needs your workspace's Slack app. Live answers in Chats only.", destination.rawValue)
            let action = FeatureEmptyState<EmptyView>.visibleAction(copy: copy, readiness: .needsFullSlack)
            XCTAssertEqual(action, .connect(.fullSlack), destination.rawValue)
            XCTAssertEqual(action.map { FeatureEmptyState<EmptyView>.label(for: $0) }, "Connect workspace app")
        }
        for tab in ["catchUp", "statistics", "digests", "people", "inbox", "memory"] {
            XCTAssertTrue(tabs.contains(tab), "\(tab) shows needsFullSlack")
        }
        XCTAssertEqual(ConnectionService(readinessSource: .fullSlack), .slack, "the button opens Connections → Slack")
    }
}
