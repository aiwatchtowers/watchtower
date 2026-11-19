import SwiftUI
import UIKit
import XCTest
@testable import WatchtowerMobile

/// The phone's tab bar (design pass spec §5, amending mobile POC spec §13
/// A4; iPhone chat spec §6.1; mobile Inbox spec §7): Now, Inbox, Workbench, Chats and Calendar, in that order;
/// Settings is pushed from Now's gear.
@MainActor
final class RootTabTests: XCTestCase {
    func testExactlyFiveTabsInOrder() {
        XCTAssertEqual(RootTabView.Tab.allCases.map(\.title), ["Now", "Inbox", "Workbench", "Chats", "Calendar"])
        XCTAssertEqual(
            RootTabView.Tab.allCases.map(\.systemImage), ["clock", "tray", "hammer", "bubble.left.and.bubble.right", "calendar"]
        )
    }

    /// Switch to Relay… (iPhone chat mockup 1e) opens Settings → Towers → this hub on Now's stack.
    func testSwitchToRelayOpensThisHubInSettings() {
        let navigation = AppNavigation()
        navigation.tab = .chats
        navigation.showTowerSettings(hubID: "hub-a", detail: true)
        XCTAssertEqual(navigation.tab, .now)
        var expected = NavigationPath()
        expected.append(NowRoute.settings)
        expected.append(NowRoute.macs)
        expected.append(MacDetailRoute(hubID: "hub-a"))
        XCTAssertEqual(navigation.nowPath, expected)

        navigation.showTowerSettings(hubID: "hub-a", detail: false)
        XCTAssertEqual(navigation.nowPath.count, 2, "without a detail screen for the hub, the list of towers")
    }

    func testAChatOpensOnTheChatsTabFromItsRoot() {
        let navigation = AppNavigation()
        navigation.chatsPath = [ChatRoute(id: 3)]
        navigation.show(conversation: 9, messageID: 41)
        XCTAssertEqual(navigation.tab, .chats)
        XCTAssertEqual(navigation.chatsPath, [ChatRoute(id: 9, messageID: 41)])
        navigation.resetStacks()
        XCTAssertEqual(navigation.chatsPath, [])
    }

    func testSettingsIsReachedFromNow() {
        // Settings, the Not delivered list (relay client Phase 1) and Settings → Macs from a refused Mac's term row
        // (relay client Phase 5, S61) are pushed from Now.
        XCTAssertEqual(NowRoute.allCases, [.settings, .notDelivered, .macs])
        XCTAssertFalse(RootTabView.Tab.allCases.map(\.rawValue).contains("more"), "More is gone")
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
