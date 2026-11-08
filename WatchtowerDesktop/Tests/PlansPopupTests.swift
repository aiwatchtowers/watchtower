import SwiftUI
import XCTest
import ViewInspector
import WatchtowerCore
@testable import WatchtowerDesktop

@MainActor
final class PlansPopupTests: XCTestCase {
    func testActualPopupRoutesProviderRetryAllRefreshAndNavigation() throws {
        var refreshed: [PlanUsageProvider] = []
        var allRefreshes = 0
        var opened = 0
        var appOpened = false
        var shown = true
        let popup = TrayPopupContent(model: PlansPopupPresentation(screen: PlansShotFixtures.model(.error)),
                                     showInMenuBar: Binding(get: { shown }, set: { shown = $0 }),
                                     openPlans: { opened += 1 }, refresh: { refreshed.append($0) },
                                     refreshAll: { allRefreshes += 1 }, actions: {
            Button("Open Watchtower") { appOpened = true }
        })
        try popup.inspect().find(button: "Retry Codex").tap()
        XCTAssertEqual(refreshed, [.codex])
        XCTAssertEqual(opened, 0)
        try popup.inspect().find(button: "Refresh").tap()
        XCTAssertEqual(allRefreshes, 1)
        try popup.inspect().find(button: "Open Plans").tap()
        XCTAssertEqual(opened, 1)
        let toggle = try popup.inspect().find(ViewType.Toggle.self)
        try toggle.tap()
        XCTAssertFalse(shown)
        try popup.inspect().find(button: "Open Watchtower").tap()
        XCTAssertTrue(appOpened)
    }

    func testLoadingPanelShowsBothSourcesAndDisablesActions() throws {
        let panel = PlansMenuPanel(model: PlansPopupPresentation(screen: PlansShotFixtures.model(.loading)),
                                   showInMenuBar: .constant(true), openPlans: {}, refresh: { _ in }, refreshAll: {})
        XCTAssertNotNil(try panel.inspect().find(text: "Loading Claude limits…"))
        XCTAssertNotNil(try panel.inspect().find(text: "Loading Codex limits…"))
        XCTAssertTrue(try panel.inspect().find(button: "Refreshing Codex…").isDisabled())
        XCTAssertTrue(try panel.inspect().find(button: "Refreshing…").isDisabled())
    }

    func testOpaqueQuotaStillAppearsAsCardRatherThanBeingDiscarded() throws {
        let model = PlansPopupPresentation(screen: PlansShotFixtures.model())
        XCTAssertEqual(model.providers[1].groups.map(\.title), ["Codex", "Review quota"])
        XCTAssertEqual(model.providers[1].groups.flatMap(\.quotas).count, 3)
        let panel = PlansMenuPanel(model: model, showInMenuBar: .constant(true), openPlans: {}, refresh: { _ in }, refreshAll: {})
        XCTAssertNotNil(try panel.inspect().find(text: "Review quota"))
        XCTAssertNotNil(try panel.inspect().find(text: "In menu bar"))
    }
}
