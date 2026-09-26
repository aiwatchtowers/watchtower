import XCTest
@testable import WatchtowerDesktop

final class ConnectionStatusLogicTests: XCTestCase {
    func testNoAccountsIsNotConfigured() {
        XCTAssertEqual(ConnectionStatusLogic.derive(okCount: 0, problemCount: 0), .notConfigured)
    }

    func testAnyProblemIsError() {
        XCTAssertEqual(ConnectionStatusLogic.derive(okCount: 2, problemCount: 1), .error)
        XCTAssertEqual(ConnectionStatusLogic.derive(okCount: 0, problemCount: 1), .error)
    }

    func testAllOKIsConnected() {
        XCTAssertEqual(ConnectionStatusLogic.derive(okCount: 1, problemCount: 0), .connected)
    }

    // MARK: - enabledFilteredStatus (Slack/Jira rows — disabled accounts are excluded)

    /// A disabled+broken account counts toward neither ok nor problem; with
    /// no other accounts the row falls back to notConfigured, not error.
    func testEnabledFilteredStatusIgnoresDisabledBrokenAccount() {
        let accounts: [(isOK: Bool, enabled: Bool)] = [(false, false)]
        XCTAssertEqual(ConnectionStatusLogic.enabledFilteredStatus(accounts), .notConfigured)
    }

    /// An enabled+broken account does produce error.
    func testEnabledFilteredStatusFlagsEnabledBrokenAccount() {
        let accounts: [(isOK: Bool, enabled: Bool)] = [(false, true)]
        XCTAssertEqual(ConnectionStatusLogic.enabledFilteredStatus(accounts), .error)
    }

    /// A disabled+broken account is excluded even when a healthy enabled
    /// account is also present — the row reads clean, not degraded.
    func testEnabledFilteredStatusIgnoresDisabledAmongMixedAccounts() {
        let accounts: [(isOK: Bool, enabled: Bool)] = [(false, false), (true, true)]
        XCTAssertEqual(ConnectionStatusLogic.enabledFilteredStatus(accounts), .connected)
    }

    // MARK: - status(okFlags:) (Google/Email/Calendar rows — every account counts)

    /// Unlike enabledFilteredStatus, this path has no enabled concept — a
    /// broken account always counts toward error.
    func testUnfilteredStatusFlagsBrokenAccountRegardless() {
        XCTAssertEqual(ConnectionStatusLogic.status(okFlags: [false]), .error)
        XCTAssertEqual(ConnectionStatusLogic.status(okFlags: [true]), .connected)
        XCTAssertEqual(ConnectionStatusLogic.status(okFlags: []), .notConfigured)
    }
}
