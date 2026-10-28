import SwiftUI
import ViewInspector
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore

/// Home's AI spend: today's `usage llm` `page_total` through the center's
/// `LLMUsageViewModel`, "—" with "AI spend unavailable" whenever there is no
/// good read (never $0), and a click that opens Usage → Watchtower.
@MainActor
final class HomeAISpendTests: XCTestCase {
    /// The shared `usage llm --json` fixture with `page_total`'s flags set.
    private func fixture(lowerBound: Bool = false, estimate: Bool = false) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)   // …/Tests/<this file>
            .deletingLastPathComponent()
            .appendingPathComponent("Core/Fixtures/llm-usage-report.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var total = try XCTUnwrap(json["page_total"] as? [String: Any])
        total["cost_is_lower_bound"] = lowerBound
        total["cost_is_estimate"] = estimate
        json["page_total"] = total
        return try JSONSerialization.data(withJSONObject: json)
    }

    private func center(_ makeRunner: @escaping () -> (any CLIRunnerProtocol)?) -> (HomeCenter, LLMUsageViewModel) {
        let usage = LLMUsageViewModel(period: .today, makeRunner: makeRunner)
        let center = HomeCenter(
            readiness: ReadinessCenter(environment: FakeReadinessEnvironment()),
            environment: FakeHomeEnvironment(),
            store: GettingReadyStore(defaults: AppState.isolatedDefaults),
            performer: FakeHomeFeedPerformer(),
            spendUsage: usage)
        return (center, usage)
    }

    private static let unavailable = HomeAISpend(value: "—", tooltip: "AI spend unavailable")

    func testAISpendIsPageTotal() async throws {
        let runner = QueuedUsageRunner([.success(try fixture())])
        let (center, usage) = center { runner }
        await usage.load()
        XCTAssertEqual(runner.argsSeen, [["usage", "llm", "--since", "today", "--json"]])
        XCTAssertEqual(runner.timeoutsSeen, [10])
        XCTAssertEqual(center.aiSpend, HomeAISpend(
            value: "$124.60",
            tooltip: "Watchtower, your automations and chats — workbenches are on Usage → Watchtower"))
    }

    func testLowerBoundMark() async throws {
        let runner = QueuedUsageRunner([
            .success(try fixture(lowerBound: true, estimate: true)),
            .success(try fixture(estimate: true))
        ])
        let (center, usage) = center { runner }
        await usage.load()
        XCTAssertEqual(center.aiSpend.value, "≥ $124.60", "a lower bound wins over an estimate, as on the tab")
        await usage.load()
        XCTAssertEqual(center.aiSpend.value, "≈ $124.60")
    }

    func testCLIErrorShowsDash() async throws {
        let good = try fixture()
        // Before the first read lands.
        XCTAssertEqual(center { nil }.0.aiSpend, Self.unavailable)

        // No CLI at all.
        let (missing, missingUsage) = center { nil }
        await missingUsage.load()
        XCTAssertEqual(missing.aiSpend, Self.unavailable)

        // A failed command, the 10 s timeout and a binary gone missing; each
        // later success replaces the dash, and a failure after a success
        // shows the dash again, never the stale number.
        for failure in [
            CLIRunnerError.nonZeroExit(code: 1, stderr: "boom"),
            CLIRunnerError.nonZeroExit(code: -1, stderr: "timed out after 10 s"),
            CLIRunnerError.binaryNotFound
        ] {
            let runner = QueuedUsageRunner([.failure(failure), .success(good), .failure(failure)])
            let (center, usage) = center { runner }
            await usage.load()
            XCTAssertEqual(center.aiSpend, Self.unavailable, "\(failure)")
            XCTAssertNotEqual(center.aiSpend.value, "$0.00")
            await usage.load()
            XCTAssertEqual(center.aiSpend.value, "$124.60", "\(failure)")
            await usage.load()
            XCTAssertEqual(center.aiSpend, Self.unavailable, "\(failure)")
        }
    }

    func testCellOpensUsageWatchtower() throws {
        var opened: [HomeLink] = []
        let view = NumbersZoneView(numbers: HomeNumbers(), aiSpend: Self.unavailable) { opened.append($0) }
        let cell = NumbersZoneView.cells(HomeNumbers(), aiSpend: Self.unavailable)
        XCTAssertEqual(cell, [NumbersZoneView.Cell(
            value: "—", caption: "AI spend today", tooltip: "AI spend unavailable", link: .usageWatchtower)])
        try view.inspect().find(ViewType.Button.self).tap()
        XCTAssertEqual(opened, [.usageWatchtower])
    }

    func testOpenUsageWatchtowerSelectsTheTab() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: UsageView.selectedTabKey)
        defer {
            if let saved { defaults.set(saved, forKey: UsageView.selectedTabKey) } else {
                defaults.removeObject(forKey: UsageView.selectedTabKey)
            }
        }
        defaults.set(UsageView.Tab.progress.rawValue, forKey: UsageView.selectedTabKey)
        let appState = AppState.isolated()
        appState.openHomeLink(.usageWatchtower)
        XCTAssertEqual(appState.selectedDestination, .usage)
        XCTAssertEqual(defaults.string(forKey: UsageView.selectedTabKey), UsageView.Tab.watchtower.rawValue)
    }
}
