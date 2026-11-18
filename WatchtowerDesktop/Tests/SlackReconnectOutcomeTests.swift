import ChatUI
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore

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
}
