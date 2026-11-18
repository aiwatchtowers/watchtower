import ChatUI
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// A card's Reconnect Slack (plan B Task 14 fix round 1): only a finished
/// built-in sign-in is "done"; the connect flow's hand-off says where to finish.
@MainActor
final class SlackReconnectOutcomeTests: XCTestCase {
    func testOutcomes() {
        let appState = AppState.isolated()
        XCTAssertEqual(appState.reconnectOutcome(route: .builtin, error: nil), .signedIn)
        XCTAssertEqual(appState.reconnectOutcome(route: .builtin, error: "Re-login failed (exit 1)"),
                       .failed("Re-login failed (exit 1)"))
        XCTAssertEqual(appState.reconnectOutcome(route: nil, error: "Another connection is already in progress."),
                       .failed("Another connection is already in progress."))
    }

    func testNoAccountsYetFails() async {
        let appState = AppState.isolated()
        let outcome = await appState.reconnectSlack(accountID: 3)
        XCTAssertEqual(outcome, .failed("Slack accounts are not loaded yet — open Connections → Slack."))
    }

    /// Set up for my company's admin connect is wired to the real connect
    /// flow on the listener (plan B A4).
    func testSetupConnectorRunsOnTheConnectFlow() async throws {
        let appState = AppState.isolated()
        let fake = FakeCLILineStream()
        let host = SlackConnectListenerHost(streamer: fake)
        let flow = appState.makeSlackConnectFlow(host: host)
        let connector = try XCTUnwrap(appState.slackAppSetup.connector as? SlackSetupConnector)
        let run = Task { await connector.connectForSetup(teamID: "T0ACME", clientID: "1111.2222") }
        let child = await fake.session(number: 1)
        await untilObserved { flow.step == .starting(SlackConnectTarget(teamID: "T0ACME", clientID: "1111.2222")) }
        XCTAssertEqual(child.writtenLines, [#"{"client_id":"1111.2222","cmd":"start","team_id":"T0ACME"}"#])
        flow.cancel()
        child.emit(#"{"event":"failed","flow":"","reason":"cancelled","message":""}"#)
        let outcome = await run.value
        XCTAssertEqual(outcome, .notConnected)
    }

    /// Fix round 1 (A13): a link clicked during onboarding stays on the
    /// onboarding window (its Connect step shows the confirm); after it,
    /// the link opens Connections → Slack.
    func testLinkDuringOnboardingStaysOnOnboarding() {
        let appState = AppState.isolated()
        let flow = appState.makeSlackConnectFlow(host: SlackConnectListenerHost(streamer: FakeCLILineStream()))
        appState.needsOnboarding = true
        let before = appState.selectedDestination
        flow.onLink?()
        XCTAssertEqual(appState.selectedDestination, before)
        appState.needsOnboarding = false
        flow.onLink?()
        XCTAssertEqual(appState.selectedDestination, .connections)
        XCTAssertEqual(appState.selectedConnection, .slack)
    }

    /// Fix round 1: onboarding wires the Slack accounts with the connect
    /// flow's entry point (the listener itself never starts under XCTest).
    func testOnboardingWiresSlackAccounts() throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let appState = AppState.isolated()
        appState.initSlackAccountsAndConnectFlow(dbPool: pool)
        XCTAssertNotNil(appState.slackAccountsViewModel)
        XCTAssertNil(appState.slackConnectListener, "never under XCTest")
    }
}
