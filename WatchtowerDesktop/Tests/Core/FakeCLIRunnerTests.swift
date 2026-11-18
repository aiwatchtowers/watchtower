import XCTest
import WatchtowerTestSupport
@testable import WatchtowerCore

/// Tests poll `invocations` from the main actor (`waitUntil`) while the code
/// under test calls `run` from other executors; the recorded list must be
/// synchronized so concurrent appends are neither lost nor racing the read.
final class FakeCLIRunnerTests: XCTestCase {
    func testConcurrentRunsAreAllRecordedAndReadableMeanwhile() async throws {
        let runner = FakeCLIRunner()
        let calls = 500
        try await withThrowingTaskGroup(of: Void.self) { group in
            for n in 0..<calls {
                group.addTask { _ = try await runner.run(args: ["call", String(n)]) }
            }
            group.addTask {
                // Reads interleaved with the appends above.
                for _ in 0..<calls { _ = runner.invocations.count }
            }
            try await group.waitForAll()
        }
        XCTAssertEqual(runner.invocations.count, calls)
        XCTAssertEqual(Set(runner.invocations.map { $0[1] }).count, calls)
    }

    /// The fake refuses a model command on its generic entries as the real
    /// runner does, so a service test catches a call site that skips
    /// `runModel` (#1886 Task 18); `runModel` records the origin it was given.
    func testFakeRefusesModelCommandWithoutOrigin() async throws {
        let runner = FakeCLIRunner(stdout: Data("ok".utf8))
        let argv = ["--config", "/x", "targets", "next-step", "4"]
        for call in [{ try await runner.run(args: argv) }, { try await runner.run(args: argv, stdin: Data()) }] {
            do {
                _ = try await call()
                XCTFail("expected modelCommandNeedsOrigin")
            } catch let CLIRunnerError.modelCommandNeedsOrigin(path) {
                XCTAssertEqual(path, "targets next-step")
            }
        }
        XCTAssertEqual(runner.invocations, [], "a refused call is not recorded as run")

        let data = try await runner.runModel(args: argv, origin: .owner, timeout: nil, stdin: Data("in".utf8))
        XCTAssertEqual(data, Data("ok".utf8))
        XCTAssertEqual(runner.invocations, [argv])
        XCTAssertEqual(runner.origins, [.owner])
        XCTAssertEqual(runner.stdinInputs, [Data("in".utf8)])
        _ = try await runner.run(args: ["targets", "list"])
        XCTAssertEqual(runner.origins, [.owner, nil])
    }
}
