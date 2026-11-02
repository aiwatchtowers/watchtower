import AppKit
import SwiftUI
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import ViewInspector

@MainActor
final class PlansScreenTests: XCTestCase {
    func testPlanTabKeepsPersistedValueAndUsesPlansTitle() {
        XCTAssertEqual(UsageView.Tab.plan.rawValue, "Claude plan")
        XCTAssertEqual(UsageView.Tab.plan.title, "Plans")
        XCTAssertEqual(UsageView.Tab.allCases.map(\.title), ["Plans", "Watchtower", "Progress", "Usage"])
    }

    func testProductionFixturesUsePublishedLinesAndSourceStates() throws {
        let filled = PlansShotFixtures.model()
        XCTAssertEqual(filled.providers.map { $0.primary?.percent }, ["76 %", "42 %"])
        XCTAssertEqual(filled.providers.map { $0.selected(.weekly)?.line?.endPercent }, [100, 55.25])
        for state in [PlansShotFixtures.State.unknownID, .stale, .error] {
            XCTAssertNil(PlansShotFixtures.model(state).providers[1].selected(.weekly)?.line)
        }
        XCTAssertTrue(PlansShotFixtures.model(.busy).isRefreshing)
        XCTAssertEqual(PlansShotFixtures.model(.predictionExpired).providers[0].selected(.weekly)?.forecast, "Forecast needs an update")
        XCTAssertNil(PlansShotFixtures.model(.predictionExpired).providers[0].selected(.weekly)?.line)
        XCTAssertTrue(PlansShotFixtures.model(.missingSession).providers.allSatisfy { $0.selected(.session) == nil })
        let collecting = PlansShotFixtures.model(.collecting).providers[0].primary?.history ?? []
        XCTAssertEqual(collecting.count, 2)
        XCTAssertLessThan(collecting[1].takenAt.timeIntervalSince(collecting[0].takenAt), 15 * 60)
        XCTAssertTrue(PlansShotFixtures.snapshot(.codex, state: .unknownID).history.isEmpty)
        XCTAssertFalse(PlansShotFixtures.model(.empty).hasLimits)
        XCTAssertEqual(PlansShotFixtures.model(.unavailable).providers[1].presentation.action, "Retry")
        XCTAssertTrue(PlansShotFixtures.trayLines(filled).contains { $0.contains("Review quota") })
    }

    func testProductionStateHeadlinesAreHonest() {
        let expected: [(PlansShotFixtures.State, String)] = [
            (.filled, "Claude may run out before reset"), (.empty, "Bring your plans together"),
            (.loading, "Reading your plan limits…"), (.busy, "Refreshing your plans"),
            (.scoped, "Showing Codex only"), (.collecting, "Collecting forecast data…"),
            (.idle, "Waiting for a usage window"), (.predictionExpired, "Forecast needs an update"),
            (.hit, "Claude limit reached"), (.stale, "Some providers need attention"),
            (.disabled, "Plan limits are turned off in Features."),
            (.readError, "Plan limits couldn't be read")
        ]
        for (state, headline) in expected { XCTAssertEqual(PlansShotFixtures.model(state).statusTitle, headline) }
        XCTAssertFalse(PlansShotFixtures.model(.scoped).warning)
        XCTAssertEqual(PlansShotFixtures.model(.scoped).statusDetail,
                       "Claude limits aren't available yet. Refresh Claude to add them.")
    }

    func testUnavailableProviderRetryAndActualTrayRowsAreActionable() throws {
        let codex = PlansShotFixtures.model(.unavailable).providers[1]
        var didRetry = false
        let card = PlansProviderCard(provider: codex, enabled: true) { didRetry = true }
        try card.inspect().find(button: "Retry").tap()
        XCTAssertTrue(didRetry)

        let lines = PlansShotFixtures.trayLines(PlansShotFixtures.model())
        let review = try XCTUnwrap(lines.first { $0.contains("Review quota") })
        var didOpen = false
        let rows = PlansTrayRows(model: PlansMenuPresentation(screen: PlansShotFixtures.model()),
                                 openPlans: { didOpen = true }, refresh: { _ in })
        try rows.inspect().find(button: review).tap()
        XCTAssertTrue(didOpen)
    }

    func testMenuStateMessagesAndProviderRetryRouteRemainVisible() throws {
        let screen = PlansShotFixtures.model(.error)
        let model = PlansMenuPresentation(screen: screen)
        XCTAssertFalse(model.providers[0].lines.isEmpty)
        XCTAssertTrue(model.providers[1].lines.isEmpty)
        XCTAssertEqual(model.providers[1].message, "Couldn't update Codex limits. Retry to update.")
        var refreshed: [PlanUsageProvider] = []
        var opened = false
        let tray = TrayMenuContent(isRunning: false, syncProgress: nil, daemonError: nil, cliStoreError: nil,
                                   voicesPendingCount: 0, planUsagePresentation: model,
                                   planUsageAction: { opened = true }, planUsageRefresh: { refreshed.append($0) },
                                   updateVersion: nil, updateAction: {}, syncNowAction: {}, quickCaptureAction: {},
                                   voicesAction: {}, reviewVoicesAction: {}, trainVoicesAction: {}, openAction: {}, settingsAction: {})
        try tray.inspect().find(button: "Retry Codex").tap()
        XCTAssertEqual(refreshed, [.codex])
        XCTAssertFalse(opened)
        try tray.inspect().find(button: "Refresh Claude").tap()
        XCTAssertEqual(refreshed, [.codex, .claude])
        try tray.inspect().find(button: "Open Plans").tap()
        XCTAssertTrue(opened)
    }

    func testMenuEmptyLoadingBusyAndUnknownIdentityCopy() throws {
        let empty = PlansMenuPresentation(screen: PlansShotFixtures.model(.empty))
        XCTAssertEqual(empty.providers.map(\.message), ["No Claude plan data yet. Refresh to load limits.",
                                                        "No Codex plan data yet. Refresh to load limits."])
        XCTAssertEqual(empty.providers.map(\.action), ["Refresh Claude", "Refresh Codex"])
        let loading = PlansMenuPresentation(screen: PlansShotFixtures.model(.loading))
        XCTAssertEqual(loading.providers.map(\.message), ["Loading Claude limits…", "Loading Codex limits…"])
        XCTAssertTrue(loading.providers.allSatisfy { !$0.canRefresh && $0.lines.isEmpty })
        let loadingRows = PlansTrayRows(model: loading, openPlans: {}, refresh: { _ in })
        XCTAssertTrue(try loadingRows.inspect().find(button: "Refreshing Codex…").isDisabled())
        let busy = PlansMenuPresentation(screen: PlansShotFixtures.model(.busy))
        XCTAssertEqual(busy.providers.map(\.message), ["Refreshing Claude limits…", "Refreshing Codex limits…"])
        XCTAssertTrue(busy.providers.allSatisfy { !$0.canRefresh && !$0.lines.isEmpty })
        let unknown = PlansShotFixtures.model(.unknownID)
        XCTAssertFalse(unknown.providers[1].showsSummary)
        XCTAssertEqual(unknown.providers[1].primary?.forecast, "Current usage only — account identity is unavailable.")
        let card = PlansProviderCard(provider: unknown.providers[1], enabled: true) {}
        let copies = try card.inspect().findAll(ViewType.Text.self) {
            try $0.string() == "Current usage only — account identity is unavailable."
        }
        XCTAssertEqual(copies.count, 1)
        let menu = PlansMenuPresentation(screen: unknown)
        XCTAssertEqual(menu.providers[1].message, "Current usage only — account identity is unavailable.")
        XCTAssertTrue(menu.providers[1].lines.allSatisfy { !$0.contains("account identity") })
        let stale = PlansMenuPresentation(screen: PlansShotFixtures.model(.stale))
        XCTAssertEqual(stale.providers[1].action, "Retry Codex")
        XCTAssertTrue(stale.providers[1].lines.isEmpty)
        let disabled = PlansMenuPresentation(screen: PlansShotFixtures.model(.disabled))
        XCTAssertTrue(disabled.providers.allSatisfy { !$0.canRefresh && $0.lines.isEmpty })
    }

    /// Explicit screenshot command renders only Plans, without opening any windows.
    func testRenderProductionPlansShots() throws {
        guard ProcessInfo.processInfo.arguments.contains(where: { $0.contains("testRenderProductionPlansShots") }) else {
            throw XCTSkip("Select this test explicitly to render production Plans shots.")
        }
        let directory = URL(fileURLWithPath: "/tmp/watchtower-plans-production-shots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for shot in PlansShotFixtures.shots {
            for (suffix, name) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let appearance = try XCTUnwrap(NSAppearance(named: name))
                let data = try ViewRenderProbe(size: shot.size).png(shot.make(), appearance)
                try data.write(to: directory.appendingPathComponent("\(shot.name)-\(suffix).png"))
                XCTAssertGreaterThan(data.count, 1000, "\(shot.name) should render production content")
            }
        }
    }
}
