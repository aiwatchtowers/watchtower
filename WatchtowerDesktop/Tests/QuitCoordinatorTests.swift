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

@MainActor
final class DaemonManagerStopTests: XCTestCase {
    func testStopForQuitBoundsHungSubprocess() async {
        // Create a temp shell script that sleeps forever
        let tempDir = FileManager.default.temporaryDirectory
        let scriptPath = tempDir.appendingPathComponent("sleeper-\(UUID().uuidString).sh").path
        let scriptContent = "#!/bin/sh\nsleep 100\n"
        _ = FileManager.default.createFile(
            atPath: scriptPath,
            contents: scriptContent.data(using: .utf8),
            attributes: [.protectionKey: FileProtectionType.none]
        )
        defer { try? FileManager.default.removeItem(atPath: scriptPath) }

        // Make executable
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptPath
        )

        let clock = ContinuousClock()
        let elapsed = await clock.measure {
            await DaemonManager.stopForQuit(
                timeout: .milliseconds(300),
                cliPath: scriptPath
            )
        }

        // Should complete in ~300ms + small grace for SIGTERM + overhead
        // Upper bound: 1 second (ensures timeout actually killed it, not full sleep)
        XCTAssertLessThan(elapsed, .seconds(1), "stopForQuit should terminate hung subprocess within timeout")
    }
}
