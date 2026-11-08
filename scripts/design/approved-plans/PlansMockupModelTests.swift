import XCTest

final class PlansMockupModelTests: XCTestCase {
    func testStateCopyAndProviderAvailability() {
        let expected: [(PlansMockupModel.State, String, String, Int)] = [
            (.filled, "Claude may run out before reset", "", 2),
            (.empty, "Bring your plans together", "Connect a provider", 0),
            (.loading, "Reading your plan limits…", "", 0),
            (.error, "Codex couldn’t refresh", "Retry", 2),
            (.busy, "Refreshing your plans", "", 2),
            (.scoped, "Showing Codex only", "Connect Claude", 1),
            (.unavailable, "Claude is up to date", "Retry Codex", 1)
        ]
        XCTAssertEqual(expected.count, PlansMockupModel.State.allCases.count)
        for (state, message, action, count) in expected {
            let model = PlansMockupModel(state)
            XCTAssertEqual(model.message, message)
            XCTAssertEqual(model.action, action)
            XCTAssertFalse(model.detail.isEmpty)
            XCTAssertEqual(model.providers.count, count)
        }
    }
    func testSharedCopyAndStaleValuesAreHonest() {
        let model = PlansMockupModel(.filled)
        XCTAssertEqual(model.title, "Plans & limits")
        XCTAssertEqual(model.tabs, ["Plans", "Watchtower", "Progress", "Usage"])
        XCTAssertEqual(model.periods, ["Weekly", "5 hours"])
        XCTAssertEqual(model.axes, ["100%", "50%", "0%"])
        XCTAssertEqual(model.surfaces.map(\.0), ["Claude Code", "Chats", "Cowork"])
        XCTAssertEqual(model.refresh, "Refresh")
        XCTAssertEqual(model.busyAction, "Refreshing…")
        XCTAssertEqual(model.stale, "Updated 18 minutes ago · refresh failed")
        XCTAssertEqual(PlansMockupModel(.busy).refreshing, "Refreshing both providers…")
        XCTAssertEqual(PlansMockupModel(.error).refreshing, "Some providers need attention")
        XCTAssertEqual(PlansMockupModel(.unavailable).providers.map(\.name), ["Claude"])
        XCTAssertEqual(PlansMockupModel(.scoped).providers.map(\.name), ["Codex"])
        XCTAssertNotEqual(model.providers[0].reset, model.providers[1].reset)
        XCTAssertEqual(model.providers.map(\.used), [76, 42])
        XCTAssertTrue(model.footer.contains("tracked separately"))
    }
    func testProjectionCopyAndEndpointsFollowProviderWindows() {
        let model = PlansMockupModel(.filled)
        let claude = model.providers[0]
        let codex = model.providers[1]
        XCTAssertEqual(claude.projection.status, .willHit)
        XCTAssertEqual(claude.projection.headline, "Limit in 1d 8h at this pace")
        XCTAssertEqual(claude.projection.detail, "Mon, 17:00 · 16h before reset")
        XCTAssertLessThan(claude.projection.hitAt!, claude.resetsAt)
        XCTAssertEqual(claude.projection.endPercent, 100)
        XCTAssertEqual(Double(claude.used) + claude.projection.ratePerHour * claude.projection.hitAt!.timeIntervalSince(PlansMockupModel.now) / 3600, 100)
        XCTAssertEqual(codex.projection.status, .safe)
        XCTAssertEqual(codex.projection.headline, "On track to last until reset")
        XCTAssertGreaterThan(codex.projection.hitAt!, codex.resetsAt)
        XCTAssertEqual(codex.projection.endPercent, 55.25)
        XCTAssertEqual(Double(codex.used) + codex.projection.ratePerHour * codex.resetsAt.timeIntervalSince(PlansMockupModel.now) / 3600, codex.projection.endPercent!)
        XCTAssertTrue(claude.projection.drawsForecast)
        XCTAssertTrue(codex.projection.drawsForecast)
        for provider in model.providers {
            XCTAssertEqual(provider.sampleTimes.first, provider.windowStart)
            XCTAssertEqual(provider.sampleTimes.last, PlansMockupModel.now)
            XCTAssertEqual(provider.resetsAt.timeIntervalSince(provider.windowStart), 7 * 24 * 3600)
        }
        let stale = PlansMockupModel(.error).providers[1].projection
        XCTAssertEqual(stale.status, .stale)
        XCTAssertEqual(stale.headline, "Forecast unavailable")
        XCTAssertFalse(stale.drawsForecast)
        XCTAssertNil(stale.endPercent)
        XCTAssertEqual(PlansMockupModel.Projection.collecting.headline, "Learning your pace…")
        XCTAssertFalse(PlansMockupModel.Projection.collecting.drawsForecast)
        XCTAssertEqual(PlansMockupModel.Projection.hit.headline, "Limit reached")
        XCTAssertFalse(PlansMockupModel.Projection.hit.drawsForecast)
        XCTAssertEqual(PlansMockupModel.Projection.idle.headline, "Window hasn’t started")
    }

    func testMenuDraftSelectionStatesAndCopy() {
        let model = PlansMenuMockupModel()
        XCTAssertEqual(model.selectedQuota?.key, "review:5h")
        XCTAssertTrue(model.barText.contains("Codex 5h 86%"))
        XCTAssertTrue(model.barText.contains("Claude 5h 38% · 7d 76%"))
        XCTAssertEqual(PlansMenuMockupModel(policy: .base).selectedQuota?.key, "codex:7d")
        XCTAssertTrue(PlansMenuMockupModel(policy: .all).barText.contains("Review quota 5h 86%"))
        XCTAssertEqual(model.quotas.count, 3)
        XCTAssertEqual(PlansMenuMockupModel(.unknownID).selectedQuota?.key, "review:5h")
        XCTAssertEqual(PlansMenuMockupModel(.unknownID).noForecast, "Current values only · forecast unavailable")
        XCTAssertEqual(PlansMenuMockupModel(.off).barText, "")
        for state in PlansMenuMockupModel.State.allCases {
            let sample = PlansMenuMockupModel(state)
            XCTAssertFalse(sample.freshness.isEmpty)
            if [.error, .stale, .empty, .loading].contains(state) {
                XCTAssertFalse(sample.hasCodex)
                XCTAssertFalse(sample.barText.contains("Codex"))
            }
            if state != .filled && state != .scoped { XCTAssertNotNil(sample.stateCopy) }
        }
        XCTAssertEqual(model.open, "Open Plans")
        XCTAssertEqual(model.retry, "Retry Codex")
        XCTAssertEqual(model.toggle, "Show limits in the menu bar")
    }

}
