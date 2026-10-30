import XCTest
@testable import WatchtowerDesktop

@MainActor
final class SlackAuthFlowStateTests: XCTestCase {

    // The legacy reconnect's `auth login` waits up to an hour for the browser:
    // Cancel and quit both end it through cancelSignIn.
    func testCancelSignInTerminatesTheRunningLogin() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        addTeardownBlock {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }

        let flow = SlackAuthFlowState()
        flow.authProcess = process
        flow.cancelSignIn()

        process.waitUntilExit()
        XCTAssertEqual(process.terminationReason, .uncaughtSignal)
        XCTAssertNil(flow.authProcess)
        XCTAssertTrue(flow.cancelRequested.withLock { $0 })
    }

    // A Cancel before the launch has no process to end; the flag is what the
    // flow's onLaunch re-check reads.
    func testCancelSignInBeforeLaunchSetsTheFlag() {
        let flow = SlackAuthFlowState()
        flow.cancelSignIn()
        XCTAssertTrue(flow.cancelRequested.withLock { $0 })
        XCTAssertNil(flow.authProcess)
    }
}
