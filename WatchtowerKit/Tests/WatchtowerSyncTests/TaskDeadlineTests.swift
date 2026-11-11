import WatchtowerE2ETesting
import XCTest

/// #1500: a test that awaits a stuck task fails with a message instead of hanging the run.
final class TaskDeadlineTests: XCTestCase {
    func testAStuckTaskFailsInsteadOfHanging() async throws {
        // Never finishes and ignores cancellation; a bare `await stuck.value` would hang here.
        let stuck = Task<Int, Never> { await withCheckedContinuation { (_: CheckedContinuation<Int, Never>) in } }
        do {
            _ = try await stuck.value(within: 0.2, "the stuck task")
            XCTFail("expected a deadline error")
        } catch let error as TaskDeadlineExceeded {
            XCTAssertEqual(error.what, "the stuck task")
            XCTAssertEqual(error.description, "the stuck task did not finish within 0.2 s")
        }
    }

    func testAFinishedTaskReturnsItsValueAndAThrowingTaskRethrows() async throws {
        let done = Task { 42 }
        let doneValue = try await done.value(within: 5)
        XCTAssertEqual(doneValue, 42)
        struct Boom: Error {}
        let failing = Task<Int, Error> { throw Boom() }
        do {
            _ = try await failing.value(within: 5)
            XCTFail("expected Boom")
        } catch is Boom {}
    }
}
