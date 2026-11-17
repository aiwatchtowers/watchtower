import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// Spec §7: the app's stops that must end the chat — the data wipe and the
/// Slack disconnect — end every chat turn and session first (`chat_shutdown`
/// over `chat.sock`, else `watchtower chat shutdown`), then stop the daemon
/// with `--internal`, which leaves sessions alone. The stops that end the app
/// (quit, wipe) refuse every daemon start behind them: the `--internal` stop
/// leaves no marker, so nothing else would.
@MainActor
final class AppStateDaemonStartTests: XCTestCase {
    /// With no chat client (`chatClient` nil, the engine cannot be asked)
    /// `shutdownChat` runs the CLI fallback, which `log` records.
    private func makeAppState(_ daemon: FakeDaemon, log: @escaping @MainActor (String) -> Void) -> AppState {
        let appState = AppState.isolated()
        appState.daemonControlOverride = daemon
        appState.chatShutdownCLI = { log("chat cli stops=\(daemon.stops)") }
        appState.daemonStartWaitBound = .milliseconds(200)
        appState.daemonStartPollInterval = .milliseconds(5)
        return appState
    }

    func testWipeShutsDownChatFirst() async {
        for running in [true, false] {
            let daemon = FakeDaemon()
            daemon.running = running
            var log: [String] = []
            let appState = makeAppState(daemon) { log.append($0) }
            let removed = await appState.stopDaemonAndRemoveEverything { log.append("remove stops=\(daemon.stops)") }
            XCTAssertTrue(removed)
            // With no daemon running the sessions may still be alive (a
            // crash): the chat is ended all the same, by the CLI fallback.
            XCTAssertEqual(log, ["chat cli stops=0", "remove stops=\(running ? 1 : 0)"], "running=\(running)")
        }
    }

    func testSlackDisconnectShutsDownChatFirst() async {
        let daemon = FakeDaemon()
        daemon.running = true
        var log: [String] = []
        let appState = makeAppState(daemon) { log.append($0) }
        let disconnected = await appState.disconnectSlackOnQueue(
            stop: { log.append("stop") },
            disconnect: { log.append("disconnect"); return true },
            start: { log.append("start") }
        )
        XCTAssertTrue(disconnected)
        XCTAssertEqual(log, ["chat cli stops=0", "stop", "disconnect", "start"])
        XCTAssertFalse(appState.stoppingForGood, "a disconnect keeps the app running")
    }

    /// T10b I2: the chat client goes unreachable after the quit's or the
    /// wipe's `--internal` stop and asks the start chain for a daemon (no
    /// marker): nothing starts.
    func testWipeRefusesDaemonStartsAfterItsStop() async {
        let daemon = FakeDaemon()
        daemon.running = true
        let appState = makeAppState(daemon) { _ in }
        let removed = await appState.stopDaemonAndRemoveEverything {
            appState.startDaemonFromBanner() // the client's auto-start, queued behind the wipe
        }
        XCTAssertTrue(removed)
        await appState.daemonStartChain?.value
        appState.startDaemonFromBanner()
        await appState.daemonStartChain?.value
        XCTAssertEqual(daemon.starts, 0, "no daemon comes back on a wiped workspace")
    }

    func testQuitRefusesDaemonStartsOnceItBegan() async throws {
        let daemon = FakeDaemon()
        let appState = makeAppState(daemon) { _ in }
        await appState.beginStopForGood()
        appState.startDaemonFromBanner()
        await appState.daemonStartChain?.value
        appState.bringUpDaemonInBackground(startOnly: true)
        try await appState.restartOnChain(daemon)
        XCTAssertEqual(daemon.starts, 0)
        XCTAssertEqual(daemon.restarts, 0)
    }

    /// A wipe whose daemon did not stop deletes nothing and the app goes on:
    /// its daemon starts come back.
    func testFailedWipeReleasesTheStop() async {
        let daemon = FakeDaemon()
        daemon.running = true
        daemon.stopTimesOut = true
        let appState = makeAppState(daemon) { _ in }
        let removed = await appState.stopDaemonAndRemoveEverything {}
        XCTAssertFalse(removed)
        XCTAssertFalse(appState.stoppingForGood)
    }
}
