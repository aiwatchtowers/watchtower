import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// Spec §7: the app's stops that must end the chat — the data wipe and the
/// Slack disconnect — end every chat turn and session first (`chat_shutdown`
/// over `chat.sock`, else `watchtower chat shutdown`), then stop the daemon
/// with `--internal`, which leaves sessions alone.
@MainActor
final class AppStateDaemonStartTests: XCTestCase {
    private func makeAppState(_ daemon: FakeDaemon, log: @escaping @MainActor (String) -> Void) -> AppState {
        let appState = AppState.isolated()
        appState.daemonControlOverride = daemon
        appState.chatShutdownOverride = { log("chat stops=\(daemon.stops)") }
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
            XCTAssertEqual(log, ["chat stops=0", "remove stops=\(running ? 1 : 0)"], "running=\(running)")
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
        XCTAssertEqual(log, ["chat stops=0", "stop", "disconnect", "start"])
    }
}
