import XCTest
@testable import WatchtowerCore

/// `restart()` must never start a second daemon next to a live one: after a
/// `sync stop` that returned non-zero (the daemon did not exit within its
/// 10 s SIGTERM grace — normal while an AI call is in flight), it polls pid
/// liveness up to `restartStopGrace` before attempting `--detach`. The poll
/// itself is a pure loop over an injected `isAlive` closure, so it is pinned
/// here without spawning any process — the process-spawning half of
/// `restart()` stays untested per house precedent (see
/// `DaemonManagerStopTests`/`DaemonManagerStartTests` for why: it would need
/// a real `daemon.pid` under `Constants.databasePath`, a global this type has
/// no test seam for).
final class DaemonManagerRestartTests: XCTestCase {
    func testDiesAtStepThreeProceeds() async {
        var calls = 0
        let outcome = await DaemonManager.waitForPidDeath(
            isAlive: {
                calls += 1
                return calls < 3
            },
            step: .milliseconds(1),
            deadline: .seconds(60)
        )

        XCTAssertEqual(outcome, .died)
        XCTAssertEqual(calls, 3, "must stop polling the instant isAlive reports death")
    }

    func testNeverDiesTimesOut() async {
        let outcome = await DaemonManager.waitForPidDeath(
            isAlive: { true },
            step: .milliseconds(1),
            deadline: .milliseconds(20)
        )

        XCTAssertEqual(outcome, .timedOut)
    }

    /// The degenerate arm: already dead on the very first check must return
    /// immediately, never sleeping once.
    func testAlreadyDeadReturnsImmediately() async {
        let elapsed = await ContinuousClock().measure {
            _ = await DaemonManager.waitForPidDeath(
                isAlive: { false },
                step: .seconds(60),
                deadline: .seconds(60)
            )
        }

        XCTAssertLessThan(elapsed, .seconds(1))
    }

    func testStopTimedOutMessageNamesThePid() {
        let message = DaemonRestartError.stopTimedOut(pid: 4242).errorDescription ?? ""
        XCTAssertTrue(message.contains("4242"), message)
    }

    func testStopTimedOutMessageToleratesUnknownPid() {
        let message = DaemonRestartError.stopTimedOut(pid: nil).errorDescription ?? ""
        XCTAssertFalse(message.isEmpty)
    }

    func testStartFailedMessageMatchesStartFailureMessage() {
        XCTAssertEqual(
            DaemonRestartError.startFailed(status: 1, stderr: "boom").errorDescription,
            DaemonManager.startFailureMessage(status: 1, stderr: "boom")
        )
    }
}
