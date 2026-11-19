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

    /// Under XCTest no Slack CLI path AppState builds for plan B starts a
    /// process: a test must never run the installed `watchtower` against the
    /// owner's live workspace (`slack app status` reads it; `slack accounts
    /// --json` runs the A17 backfill UPDATE). The setup's record read, the
    /// accounts flags and Re-login route reads and the listener all refuse.
    func testIsolatedAppStateRunsNoSlackCLI() async throws {
        XCTAssertNil(AppState.slackLineStream(), "no streamer in a test process")
        XCTAssertNil(AppState.slackCLIPath(), "no CLI path in a test process")
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        try await pool.write { db in _ = try TestDatabase.insertSlackAccount(db, teamName: "Acme") }
        let appState = AppState.isolated()
        appState.initSlackAccountsAndConnectFlow(dbPool: pool)
        XCTAssertNil(appState.slackConnectListener)

        let records = await appState.slackAppSetup.reloadRecords()
        XCTAssertNil(records, "the setup's status read has no CLI to run")
        appState.slackAppSetup.accountsChanged() // the same read, from the pane's accounts change

        let vm = try XCTUnwrap(appState.slackAccountsViewModel)
        await vm.refreshFlags()
        XCTAssertNil(vm.accountFlags, "the flags read has no CLI to run")
        let route = await vm.reloginRoute(accountID: 1)
        XCTAssertEqual(route, .failure(.init("Watchtower CLI not found")))
    }

    /// Fix round 2: a link clicked after onboarding's Connect step is shown
    /// once onboarding ends: Connections → Slack, where the confirm lives.
    func testPendingLinkShowsAfterOnboardingEnds() {
        let appState = AppState.isolated()
        let host = SlackConnectListenerHost(streamer: FakeCLILineStream())
        let flow = appState.makeSlackConnectFlow(host: host)
        appState.slackConnectFlow = flow
        appState.needsOnboarding = true
        host.onEvent?(.link(flow: "f1", teamID: "T0ACME", clientID: "1111.2222"))
        XCTAssertTrue(flow.showsSheet)
        XCTAssertNotEqual(appState.selectedDestination, .connections, "onboarding stays on screen")

        appState.needsOnboarding = false
        XCTAssertEqual(appState.selectedDestination, .connections)
        XCTAssertEqual(appState.selectedConnection, .slack)
    }

    /// No pending flow: ending onboarding routes nowhere.
    func testNoPendingLinkLeavesTheDestination() {
        let appState = AppState.isolated()
        appState.slackConnectFlow = appState.makeSlackConnectFlow(
            host: SlackConnectListenerHost(streamer: FakeCLILineStream()))
        appState.needsOnboarding = true
        let before = appState.selectedDestination
        appState.needsOnboarding = false
        XCTAssertEqual(appState.selectedDestination, before)
        XCTAssertFalse(appState.showPendingSlackConnect())
    }
}
