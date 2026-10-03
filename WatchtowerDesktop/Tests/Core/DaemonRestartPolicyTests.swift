import XCTest
import WatchtowerTestSupport
@testable import WatchtowerCore

final class DaemonRestartPolicyTests: XCTestCase {
    func testRestartRunsTheRestarterOnce() async throws {
        let daemon = FakeDaemonRestarter()
        let task = try XCTUnwrap(DaemonRestartPolicy.restart.apply(using: daemon))
        await task.value
        XCTAssertEqual(daemon.restartCount, 1)
    }

    func testDeferredNeverRestarts() {
        let daemon = FakeDaemonRestarter()
        XCTAssertNil(DaemonRestartPolicy.deferred.apply(using: daemon))
        XCTAssertEqual(daemon.restartCount, 0)
    }
}
