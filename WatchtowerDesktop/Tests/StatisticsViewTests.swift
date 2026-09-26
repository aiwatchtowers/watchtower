import XCTest
import SwiftUI
import ViewInspector
@testable import WatchtowerDesktop

@MainActor
final class StatisticsViewTests: XCTestCase {

    /// TabView присутствует — корневой контейнер.
    func testTabViewPresent() throws {
        let view = StatisticsView()
        XCTAssertNoThrow(try view.inspect().find(ViewType.TabView.self))
    }

    /// Активный таб по умолчанию (tag 0) — ChannelStatisticsView.
    /// SwiftUI инстанцирует только активный TabView-чайлд, поэтому неактивные
    /// табы отсутствуют в дереве на этапе инспекции — проверяем только
    /// дефолтный selectedTab.
    func testDefaultActiveTabIsChannel() throws {
        let tabView = try StatisticsView().inspect().find(ViewType.TabView.self)
        XCTAssertNoThrow(try tabView.view(ChannelStatisticsView.self, 0))
    }
}
