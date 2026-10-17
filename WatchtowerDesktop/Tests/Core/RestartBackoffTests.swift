import XCTest
@testable import WatchtowerCore

/// Board #526: the pause before a failed observation starts again.
final class RestartBackoffTests: XCTestCase {
    func testThePauseDoublesUpToTheCap() {
        var backoff = RestartBackoff(first: .seconds(2), max: .seconds(10))
        XCTAssertEqual(backoff.failed(), .seconds(2))
        XCTAssertEqual(backoff.failed(), .seconds(4))
        XCTAssertEqual(backoff.failed(), .seconds(8))
        XCTAssertEqual(backoff.failed(), .seconds(10))
        XCTAssertEqual(backoff.failed(), .seconds(10))
    }

    func testADeliveryResetsThePause() {
        var backoff = RestartBackoff(first: .seconds(2), max: .seconds(60))
        _ = backoff.failed()
        _ = backoff.failed()
        backoff.succeeded()
        XCTAssertEqual(backoff.failed(), .seconds(2))
    }

    func testACapBelowTheFirstPauseIsTheFirstPause() {
        var backoff = RestartBackoff(first: .seconds(5), max: .seconds(1))
        XCTAssertEqual(backoff.failed(), .seconds(5))
        XCTAssertEqual(backoff.failed(), .seconds(5))
    }

    func testTheStandardPauses() {
        let backoff = RestartBackoff()
        XCTAssertEqual(backoff.first, .seconds(2))
        XCTAssertEqual(backoff.max, .seconds(60))
    }
}
