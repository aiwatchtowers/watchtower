import XCTest
@testable import WatchtowerCore

final class PlansScreenPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testCopyAndEmptyLoadingDisabledStates() {
        let empty = PlansScreenPresentation(claude: nil, codex: nil, now: now)
        XCTAssertEqual(empty.statusTitle, "Bring your plans together")
        XCTAssertEqual(empty.statusDetail, "Sign in to Claude Code or Codex, then refresh to load your subscription limits.")
        XCTAssertEqual(empty.providers.map(\.presentation.title), ["Claude", "Codex"])
        XCTAssertFalse(empty.hasLimits)
        let loading = PlansScreenPresentation(claude: nil, codex: nil, refreshing: [.claude, .codex], now: now)
        XCTAssertEqual(loading.statusTitle, "Reading your plan limits…")
        XCTAssertEqual(loading.refreshTitle, "Refreshing…")
        XCTAssertEqual(PlansScreenCopy.providerAction(loading.providers[0].presentation), "Refreshing Claude…")
        XCTAssertEqual(PlansScreenCopy.providerAction(empty.providers[1].presentation), "Refresh Codex")
        let disabled = PlansScreenPresentation(claude: nil, codex: nil, now: now, enabled: false)
        XCTAssertEqual(disabled.statusTitle, "Plan limits are turned off in Features.")
        XCTAssertEqual(disabled.statusDetail, "Turn on plan limits in Features to refresh both subscriptions.")
        XCTAssertEqual(PlansScreenCopy.heading, "Plans & limits")
        XCTAssertEqual(PlansScreenCopy.subtitle, "Your subscriptions, in one place.")
        XCTAssertEqual(PlansScreenCopy.menu, "Show limits in the menu bar")
        XCTAssertEqual(PlansScreenCopy.axes, ["100%", "50%", "0%"])
        XCTAssertEqual(PlansScreenCopy.historyNote, "Solid: usage so far · Dashed: forecast at your current pace")
        XCTAssertEqual(PlansScreenCopy.footer, "Subscription percentages are tracked separately. API costs live in Watchtower.")
        XCTAssertEqual(PlansScreenCopy.tabsTitle, "Statistics")
        XCTAssertEqual(PlansScreenCopy.used, "used")
        XCTAssertEqual(PlansScreenCopy.history, "This week")
        XCTAssertEqual(PlansScreenCopy.periodTitle, "Limit window")
        XCTAssertEqual(PlansScreenCopy.otherLimits, "Additional limits")
        XCTAssertEqual(PlansScreenCopy.breakdown, "Claude usage by surface")
        XCTAssertEqual(PlansScreenCopy.open, "Open Plans")
        XCTAssertEqual(PlansScreenCopy.unavailable, "Usage history is unavailable for this window.")
        XCTAssertEqual(PlansScreenCopy.windowTitle(.weekly), "Weekly usage")
        XCTAssertEqual(PlansScreenCopy.windowTitle(.session), "5-hour window")
        XCTAssertEqual(PlansScreenCopy.historyTitle(.weekly), "This week")
        XCTAssertEqual(PlansScreenCopy.historyTitle(.session), "5-hour history")
    }

    func testAbsentSelectedWindowDoesNotFallBackToWeekly() {
        let weekly = PlanUsageLimit(key: "weekly_all", label: "Weekly", group: "weekly", percent: 42,
                                    resetsAt: now.addingTimeInterval(3600), severity: nil,
                                    projection: PlanUsageProjection(state: "collecting", hitAt: nil, ratePerHour: 0), windowDurationMinutes: 10080)
        let status = PlanUsageStatus(state: "ok", reason: "", plan: "Max", fetchedAt: now, lastError: "", limits: [weekly], breakdown: [])
        let screen = PlansScreenPresentation(claude: status, codex: nil, now: now)
        XCTAssertEqual(screen.providers[0].selected(.weekly)?.key, weekly.key)
        XCTAssertNil(screen.providers[0].selected(.session))
        XCTAssertEqual(PlansScreenCopy.missingWindow(.session), "This subscription does not provide a 5-hour limit.")
        XCTAssertEqual(PlansScreenCopy.missingWindow(.weekly), "This subscription does not provide a weekly limit.")
        XCTAssertEqual(PlansPeriod.allCases.map(\.title), ["Weekly", "5 hours"])
        let session = PlanUsageLimit(key: "reversed:secondary", label: "5 hours", group: "weekly", percent: 17,
                                     resetsAt: now.addingTimeInterval(3600), severity: nil,
                                     projection: PlanUsageProjection(state: "collecting", hitAt: nil, ratePerHour: 0), windowDurationMinutes: 300)
        let swapped = PlanUsageStatus(state: "ok", reason: "", plan: "", fetchedAt: now, lastError: "",
                                      limits: [weekly, session], breakdown: [])
        let selected = PlansScreenPresentation(claude: swapped, codex: nil, now: now).providers[0]
        XCTAssertEqual(selected.selected(.session)?.key, "reversed:secondary")
        XCTAssertEqual(selected.selected(.weekly)?.key, "weekly_all")
    }

    func testCorruptProviderDoesNotBlockOtherCard() {
        let broken = PlanUsageLimit(key: "bad", label: "Bad", group: "weekly", percent: 42,
                                    resetsAt: now.addingTimeInterval(3600), severity: nil,
                                    projection: PlanUsageProjection(state: "unknown", hitAt: nil, ratePerHour: 0), windowDurationMinutes: 10080)
        let corrupt = PlanUsageStatus(state: "ok", reason: "", plan: "", fetchedAt: now, lastError: "", limits: [broken], breakdown: [])
        let screen = PlansScreenPresentation(claude: corrupt, codex: nil, now: now)
        XCTAssertEqual(screen.providers[0].presentation.summary, "Couldn't read saved limits. Retry to reload.")
        XCTAssertEqual(screen.providers[1].presentation.summary, "No Codex plan data yet. Refresh to load limits.")
        XCTAssertEqual(screen.providers[0].presentation.action, "Retry")
        XCTAssertEqual(screen.statusTitle, "Plan limits couldn't be read")
        XCTAssertEqual(screen.statusDetail, "Check each provider's message, then retry. Providers update independently.")
        XCTAssertEqual(PlansScreenCopy.providerAction(screen.providers[0].presentation), "Retry Claude")
    }
}
