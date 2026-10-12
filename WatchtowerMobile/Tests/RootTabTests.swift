import UIKit
import XCTest
@testable import WatchtowerMobile

/// The phone's tab bar (design pass spec §5, amending mobile POC spec §13
/// A4): Now, Workbench and Calendar, in that order; Settings is pushed from
/// Now's gear.
@MainActor
final class RootTabTests: XCTestCase {
    func testExactlyThreeTabsInOrder() {
        XCTAssertEqual(RootTabView.Tab.allCases.map(\.title), ["Now", "Workbench", "Calendar"])
        XCTAssertEqual(RootTabView.Tab.allCases.map(\.systemImage), ["clock", "hammer", "calendar"])
    }

    func testSettingsIsReachedFromNow() {
        XCTAssertEqual(NowRoute.allCases, [.settings])
        XCTAssertFalse(RootTabView.Tab.allCases.map(\.rawValue).contains("more"), "More is gone")
    }

    /// Spec §3: the foreground fetch runs every 5 s while Now (Settings
    /// included) or Workbench is on screen and every 30 s on Calendar.
    func testForegroundFetchIsFastOnNowAndWorkbenchOnly() {
        XCTAssertEqual(RootTabView.Tab.now.fetchInterval, .seconds(5))
        XCTAssertEqual(RootTabView.Tab.workbench.fetchInterval, .seconds(5))
        XCTAssertEqual(RootTabView.Tab.calendar.fetchInterval, .seconds(30))
    }

    /// §5: the open-ask badge is orange on every tab bar item layout, not
    /// only through `UITabBarItem.appearance()`.
    func testTheBadgeIsOrangeOnEveryTabBarLayout() {
        RootTabView.configureTabBarAppearance()
        let appearance = UITabBar.appearance().standardAppearance
        for layout in [appearance.stackedLayoutAppearance, appearance.inlineLayoutAppearance, appearance.compactInlineLayoutAppearance] {
            XCTAssertEqual(layout.normal.badgeBackgroundColor, .systemOrange)
            XCTAssertEqual(layout.selected.badgeBackgroundColor, .systemOrange)
        }
        XCTAssertEqual(UITabBar.appearance().scrollEdgeAppearance?.stackedLayoutAppearance.normal.badgeBackgroundColor, .systemOrange)
    }
}
