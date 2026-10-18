import XCTest
@testable import WatchtowerCore

/// Board #670: a pane's first-use chat creates are keyed by context, so a
/// create still under way for one recording or track never blocks the next
/// one's (the pane would otherwise spin for good on the second).
final class ChatCreateGateTests: XCTestCase {
    func testAnotherContextStartsItsOwnCreateWhileOneIsUnderWay() {
        var gate = ChatCreateGate()
        XCTAssertTrue(gate.begin("recording-a"))
        XCTAssertTrue(gate.begin("recording-b"), "B is never blocked by A's create")
        XCTAssertTrue(gate.isCreating("recording-a"))
        XCTAssertTrue(gate.isCreating("recording-b"))
    }

    func testTheSameContextCreatesOnceUntilItEnded() {
        var gate = ChatCreateGate()
        XCTAssertTrue(gate.begin("track-1"))
        XCTAssertFalse(gate.begin("track-1"), "a second open while its create waits does nothing")
        gate.end("track-1")
        XCTAssertFalse(gate.isCreating("track-1"))
        XCTAssertTrue(gate.begin("track-1"), "a later open (after a failure) tries again")
    }
}
