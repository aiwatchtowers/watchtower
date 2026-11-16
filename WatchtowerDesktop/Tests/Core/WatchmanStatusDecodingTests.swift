import XCTest
@testable import WatchtowerCore
import WatchtowerTestSupport

/// `watchman status --json` (`cmd/watchman.go`) decodes on the Swift side —
/// the Go-written fixture and the pinned keys — and the screen state follows
/// from it.
final class WatchmanStatusDecodingTests: XCTestCase {
    /// The fixture Go's `TestWatchmanStatus_JSONKeysPinned` writes.
    func testGoFixtureDecodes() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("internal/watchman/testdata/status.json")
        let status = try JSONDecoder().decode(WatchmanStatus.self, from: Data(contentsOf: url))
        XCTAssertTrue(status.ok)
        XCTAssertFalse(status.workbenches.isEmpty)
        for row in status.workbenches {
            XCTAssertFalse(row.name.isEmpty)
            for backtest in [row.backtest, row.lastDone].compactMap({ $0 }) {
                for category in backtest.categories {
                    XCTAssertTrue(["strong", "weak", "not_measured"].contains(category.status), category.status)
                }
            }
        }
    }

    func testEveryPinnedKeyDecodes() throws {
        let status = try WatchmanStatusFixtures.decode(WatchmanStatusFixtures.results)
        let row = try XCTUnwrap(status.workbenches.first)
        XCTAssertEqual(row.workbench, 1)
        XCTAssertEqual(row.name, "acme-web")
        XCTAssertEqual(row.enabledAt, "2026-11-08T21:04:00Z")
        XCTAssertFalse(row.analyticsOn)
        XCTAssertEqual(row.precedents["permission"], 88)
        XCTAssertEqual(row.sources["ask"], WatchmanSourceProgress(written: 120, done: true))
        XCTAssertEqual(row.sleepWindow, "00:30-07:45")
        XCTAssertFalse(row.sleepWindowPinned)
        XCTAssertNil(row.estimate)
        XCTAssertEqual(row.learning, WatchmanLearning(written: 317, estimated: 320, done: true))
        XCTAssertFalse(row.running)
        let done = try XCTUnwrap(row.lastDone)
        XCTAssertEqual(done.id, 7)
        XCTAssertEqual(done.status, "done")
        XCTAssertEqual(done.verdict, "go")
        XCTAssertEqual(done.costUSD, 2.75)
        XCTAssertEqual(done.categories.first, WatchmanBacktestCategory(
            category: "design", total: 30, agree: 25, wrongHigh: 1, costUSD: 0.4, status: "strong"))
        XCTAssertTrue(row.isLearned)
    }

    func testNotEnabledRowCarriesItsEstimateAndNulls() throws {
        let status = try WatchmanStatusFixtures.decode(WatchmanStatusFixtures.notLearned)
        let row = try XCTUnwrap(status.workbenches.first)
        XCTAssertNil(row.enabledAt)
        XCTAssertFalse(row.isEnabled)
        XCTAssertEqual(row.estimate, WatchmanEstimate(decisions: 1850, needLabels: 1200, tokens: 1_600_000))
        XCTAssertNil(row.learning)
        XCTAssertNil(row.backtest)
        XCTAssertNil(row.lastDone)
    }

    /// A nil Go slice is `null` on the wire: an empty list, not a failure.
    func testNullWorkbenchesIsEmpty() throws {
        let status = try WatchmanStatusFixtures.decode(#"{"ok":true,"workbenches":null}"#)
        XCTAssertEqual(status.workbenches, [])
        XCTAssertEqual(WatchmanSettingsState.of(status), .notLearned(status))
    }

    func testStateFollowsTheFocusWorkbench() throws {
        let notLearned = try WatchmanStatusFixtures.decode(WatchmanStatusFixtures.notLearned)
        XCTAssertEqual(WatchmanSettingsState.of(notLearned), .notLearned(notLearned))
        XCTAssertEqual(WatchmanSettingsState.of(notLearned, learningHere: [2]), .learning(notLearned, workbench: 2))

        let learning = try WatchmanStatusFixtures.decode(WatchmanStatusFixtures.learning)
        XCTAssertEqual(WatchmanSettingsState.of(learning), .learning(learning, workbench: 2))

        let neverRun = try WatchmanStatusFixtures.decode(WatchmanStatusFixtures.neverRun)
        XCTAssertEqual(WatchmanSettingsState.of(neverRun), .neverRun(neverRun))
        XCTAssertEqual(WatchmanSettingsState.of(neverRun, backtestHere: [1]), .running(neverRun, progress: ""))

        let running = try WatchmanStatusFixtures.decode(WatchmanStatusFixtures.running)
        XCTAssertEqual(WatchmanSettingsState.of(running),
                       .running(running, progress: "ux_text, 18 of 30 · 3 of 8 categories done"))

        let failed = try WatchmanStatusFixtures.decode(WatchmanStatusFixtures.failed)
        XCTAssertEqual(WatchmanSettingsState.of(failed),
                       .failed(failed, message: "the AI provider hit your plan limit"))

        let results = try WatchmanStatusFixtures.decode(WatchmanStatusFixtures.results)
        XCTAssertEqual(WatchmanSettingsState.of(results), .results(results))
        XCTAssertEqual(WatchmanSettingsState.of(results).status, results)
    }

    /// `interrupted` (a running row whose process died) shows like `failed`.
    func testInterruptedShowsAsFailed() throws {
        let json = WatchmanStatusFixtures.failed.replacingOccurrences(of: #""status": "failed""#,
                                                                      with: #""status": "interrupted""#)
        let status = try WatchmanStatusFixtures.decode(json)
        guard case .failed = WatchmanSettingsState.of(status) else {
            return XCTFail("interrupted must show as failed")
        }
    }
}
