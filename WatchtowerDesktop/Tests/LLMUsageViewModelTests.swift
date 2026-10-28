import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore

/// Answers each call from a queue of results (the last one repeats) and
/// records the argv and timeout. No process is spawned.
private final class QueuedUsageRunner: CLIRunnerProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<Data, Error>]
    private var calls: [([String], TimeInterval?)] = []

    init(_ results: [Result<Data, Error>]) { self.results = results }

    var argsSeen: [[String]] { lock.withLock { calls.map(\.0) } }
    var timeoutsSeen: [TimeInterval?] { lock.withLock { calls.map(\.1) } }

    private func next(_ args: [String], _ timeout: TimeInterval?) throws -> Data {
        let result: Result<Data, Error> = lock.withLock {
            calls.append((args, timeout))
            return results.count > 1 ? results.removeFirst() : results[0]
        }
        return try result.get()
    }

    func run(args: [String]) async throws -> Data { try next(args, nil) }
    func run(args: [String], timeout: TimeInterval) async throws -> Data { try next(args, timeout) }
}

@MainActor
final class LLMUsageViewModelTests: XCTestCase {
    private func fixture() throws -> Data {
        let url = URL(fileURLWithPath: #filePath)   // …/Tests/<this file>
            .deletingLastPathComponent()
            .appendingPathComponent("Core/Fixtures/llm-usage-report.json")
        return try Data(contentsOf: url)
    }

    private let now = Date(timeIntervalSince1970: 1_793_188_800)  // 2026-10-28T12:00:00Z

    private func model(_ runner: QueuedUsageRunner?, period: LLMUsagePeriod = .sevenDays) -> LLMUsageViewModel {
        LLMUsageViewModel(period: period, makeRunner: { runner }, now: { [now] in now })
    }

    func testPeriodGoesToTheArgs() async throws {
        let runner = QueuedUsageRunner([.success(try fixture())])
        let vm = model(runner)
        await vm.load()
        vm.period = .today
        await vm.load()
        vm.period = .thirtyDays
        await vm.load()
        XCTAssertEqual(runner.argsSeen, [
            ["usage", "llm", "--since", "7d", "--json"],
            ["usage", "llm", "--since", "today", "--json"],
            ["usage", "llm", "--since", "30d", "--json"]
        ])
        XCTAssertEqual(runner.timeoutsSeen, [10, 10, 10])
    }

    func testLoadDecodesTheReport() async throws {
        let vm = model(QueuedUsageRunner([.success(try fixture())]))
        XCTAssertEqual(vm.screen(now: now), .loading)
        await vm.load()
        XCTAssertEqual(vm.report?.watchtower.totals.calls, 1284)
        XCTAssertNil(vm.error)
        XCTAssertEqual(vm.lastUpdated, now)
        guard case .report = vm.screen(now: now) else { return XCTFail("expected the report") }
    }

    func testEmptyLedgerFlag() async throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture()) as? [String: Any])
        json["ledger_since"] = ""
        let vm = model(QueuedUsageRunner([.success(try JSONSerialization.data(withJSONObject: json))]))
        await vm.load()
        XCTAssertEqual(vm.screen(now: now), .emptyLedger)
    }

    func testErrorGivesTheErrorState() async {
        let vm = model(QueuedUsageRunner([.failure(CLIRunnerError.nonZeroExit(code: -1, stderr: "timed out after 10 s"))]))
        await vm.load()
        XCTAssertNil(vm.report)
        XCTAssertEqual(vm.error, .timedOut)
        XCTAssertEqual(vm.screen(now: now), .failed(.timedOut))
    }

    func testMissingCLIGivesTheErrorState() async {
        let vm = model(nil)
        await vm.load()
        XCTAssertEqual(vm.screen(now: now), .failed(.cliMissing))
    }

    func testUndecodableOutputGivesTheErrorState() async {
        let vm = model(QueuedUsageRunner([.success(Data("not json".utf8))]))
        await vm.load()
        XCTAssertEqual(vm.error, .unreadable)
    }

    func testRefreshFailureKeepsTheLastReport() async throws {
        let runner = QueuedUsageRunner([
            .success(try fixture()),
            .failure(CLIRunnerError.nonZeroExit(code: 1, stderr: "database is locked"))
        ])
        let vm = model(runner)
        await vm.load()
        let first = vm.report
        await vm.load()
        XCTAssertEqual(vm.report, first)
        XCTAssertEqual(vm.error, .failed(exitCode: 1))
        guard case let .report(_, _, failedAt) = vm.screen(now: now) else { return XCTFail("expected the report") }
        XCTAssertEqual(failedAt, now)
    }

    /// Retry after a failure clears the error once the command answers.
    func testSuccessAfterAFailureClearsTheError() async throws {
        let runner = QueuedUsageRunner([
            .failure(CLIRunnerError.binaryNotFound),
            .success(try fixture())
        ])
        let vm = model(runner)
        await vm.load()
        XCTAssertEqual(vm.error, .cliMissing)
        await vm.load()
        XCTAssertNil(vm.error)
        XCTAssertNotNil(vm.report)
    }

    /// Another period's numbers never stay on screen under the new period.
    func testChangingThePeriodDropsTheOldReport() async throws {
        let vm = model(QueuedUsageRunner([.success(try fixture())]))
        await vm.load()
        vm.period = .today
        XCTAssertNil(vm.report)
        XCTAssertEqual(vm.screen(now: now), .loading)
        vm.period = .today
        XCTAssertEqual(vm.screen(now: now), .loading)
    }
}
