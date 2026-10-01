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
}
