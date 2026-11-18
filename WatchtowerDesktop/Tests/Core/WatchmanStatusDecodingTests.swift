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
        XCTAssertEqual(status.workbenches.count, 2)

        // Enabled, still learning, a backtest running under the lock.
        let first = status.workbenches[0]
        XCTAssertEqual(first.workbench, 1)
        XCTAssertEqual(first.name, "acme")
        XCTAssertEqual(first.enabledAt, "2026-11-02T09:00:00Z")
        XCTAssertFalse(first.analyticsOn)
        XCTAssertEqual(first.precedents.count, 8)
        XCTAssertEqual(first.precedents["scope"], 3)
        XCTAssertEqual(first.sources.count, 6)
        XCTAssertEqual(first.sources["ask"], WatchmanSourceProgress(written: 3, done: false))
        XCTAssertEqual(first.sleepWindow, "23:00-07:00")
        XCTAssertTrue(first.sleepWindowPinned)
        XCTAssertNil(first.estimate)
        XCTAssertEqual(first.learning, WatchmanLearning(written: 6, estimated: 120, done: false, relabelPending: 5))
        XCTAssertTrue(first.running)
        let running = try XCTUnwrap(first.backtest)
        XCTAssertEqual(running.id, 2)
        XCTAssertEqual(running.status, "running")
        XCTAssertNil(running.finishedAt)
        XCTAssertEqual(running.categories, [])
        let done = try XCTUnwrap(first.lastDone)
        XCTAssertEqual(done.id, 1)
        XCTAssertEqual(done.status, "done")
        XCTAssertEqual(done.verdict, "go")
        XCTAssertEqual(done.costUSD, 1.25)
        XCTAssertEqual(done.categories, [WatchmanBacktestCategory(
            category: "permission", total: 28, agree: 24, acceptable: 3, bad: 1, wrongHigh: 0, handed: 2,
            costUSD: 0.75, baseline: 0.6, recBaseline: 0.7, status: "strong")])
        guard case let .running(progress) = WatchmanWorkbenchPhase.of(first) else {
            return XCTFail("row 1 must be running")
        }
        XCTAssertEqual(try XCTUnwrap(WatchmanSettingsCopy.progressFraction(progress)),
                       (3 + 12.0 / 30) / 8, accuracy: 0.0001)

        // Not on yet: the estimate only.
        let second = status.workbenches[1]
        XCTAssertEqual(second.workbench, 2)
        XCTAssertNil(second.enabledAt)
        XCTAssertEqual(second.estimate, WatchmanEstimate(decisions: 5, needLabels: 5, tokens: 1750))
        XCTAssertNil(second.learning)
        XCTAssertNil(second.backtest)
        XCTAssertNil(second.lastDone)
        XCTAssertEqual(second.sleepWindow, "")
        // `running` is the workspace-wide lock, the same on every row.
        XCTAssertTrue(second.running)
        XCTAssertEqual(WatchmanWorkbenchPhase.of(second), .notLearned)
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
            category: "design", total: 30, agree: 25, wrongHigh: 1, costUSD: 0.4, baseline: 0.5, status: "strong"))
        // A row from before the judge grades decodes them as 0.
        let first = try XCTUnwrap(done.categories.first)
        XCTAssertEqual([first.acceptable, first.bad], [0, 0])
        XCTAssertEqual(first.recBaseline, 0)
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

    func testDecodesHanded() throws {
        let status = try WatchmanStatusFixtures.decode(WatchmanStatusFixtures.results)
        let rows = try XCTUnwrap(status.workbenches.first?.lastDone).categories
        XCTAssertEqual(rows.last?.category, "finish")
        XCTAssertEqual(rows.last?.handed, 18)
        XCTAssertEqual(rows.first?.handed, 0)
    }

    func testHandedMissingIsZero() throws {
        let status = try WatchmanStatusFixtures.decode(#"""
        {"ok": true, "workbenches": [{"workbench": 1, "name": "acme", "enabled_at": "2026-11-02T09:00:00Z",
          "analytics_on": true, "running": false, "last_done": {"id": 1, "status": "done", "cost_usd": 0,
          "categories": [{"category": "permission", "total": 30, "agree": 26, "wrong_high": 1,
                          "status": "strong", "cost_usd": 0.75}]}}]}
        """#)
        XCTAssertEqual(status.workbenches[0].lastDone?.categories.first?.handed, 0)
    }

    func testDecodesRelabelPending() throws {
        let relabelling = try WatchmanStatusFixtures.decode(WatchmanStatusFixtures.relabelling)
        XCTAssertEqual(relabelling.workbenches[0].learning?.relabelPending, 340)
        XCTAssertTrue(relabelling.workbenches[0].isRelabelling)
        // A learning object without the key (an older CLI) is not relabelling.
        let plain = try WatchmanStatusFixtures.decode(WatchmanStatusFixtures.results)
        XCTAssertEqual(plain.workbenches[0].learning?.relabelPending, 0)
        XCTAssertFalse(plain.workbenches[0].isRelabelling)
    }

    /// The journal's daemon line reads `daemon_running`; a CLI that does
    /// not print it leaves it unknown (no line).
    func testDaemonRunningDecodesAndMissingIsUnknown() throws {
        func decode(_ json: String) throws -> WatchmanStatus {
            try JSONDecoder().decode(WatchmanStatus.self, from: Data(json.utf8))
        }
        XCTAssertEqual(try decode(#"{"ok":true,"workbenches":[],"daemon_running":false}"#).daemon, .stopped)
        XCTAssertEqual(try decode(#"{"ok":true,"workbenches":[],"daemon_running":true}"#).daemon, .running)
        XCTAssertEqual(try decode(#"{"ok":true,"workbenches":[]}"#).daemon, .unknown)
    }
}
