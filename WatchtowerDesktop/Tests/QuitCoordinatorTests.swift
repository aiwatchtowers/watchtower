import XCTest
import AppKit
@testable import WatchtowerDesktop

@MainActor
final class QuitCoordinatorTests: XCTestCase {
    func testNotCapturingSkipsConfirmAndTerminatesLater() async {
        var confirmAsked = false
        let stopped = expectation(description: "daemon stopped")
        let replied = expectation(description: "replied true")
        let reply = QuitCoordinator.shouldTerminate(
            isCapturing: false,
            confirmQuit: { confirmAsked = true; return true },
            stopDaemon: { stopped.fulfill() },
            reply: { ok in XCTAssertTrue(ok); replied.fulfill() })
        XCTAssertEqual(reply, .terminateLater)
        XCTAssertFalse(confirmAsked)
        await fulfillment(of: [stopped, replied], timeout: 5)
    }

    func testCapturingCancelBlocksQuitWithoutStopping() {
        var stoppedCalled = false
        let reply = QuitCoordinator.shouldTerminate(
            isCapturing: true,
            confirmQuit: { false },
            stopDaemon: { stoppedCalled = true },
            reply: { _ in XCTFail("must not reply when quit is cancelled") })
        XCTAssertEqual(reply, .terminateCancel)
        XCTAssertFalse(stoppedCalled)
    }

    func testCapturingConfirmedProceeds() async {
        let replied = expectation(description: "replied")
        let reply = QuitCoordinator.shouldTerminate(
            isCapturing: true,
            confirmQuit: { true },
            stopDaemon: {},
            reply: { ok in XCTAssertTrue(ok); replied.fulfill() })
        XCTAssertEqual(reply, .terminateLater)
        await fulfillment(of: [replied], timeout: 5)
    }
}
