import Foundation

extension AppState {
    /// Cancel on an agent card's waiting Reconnect Slack: ends the sign-in
    /// the card started for `accountID` (`reconnectSlack`), silently, and no
    /// other Slack sign-in. Named apart from `SlackConnectionDetail`'s
    /// `cancelSlackReconnect`, which cancels the legacy workspace reconnect.
    func cancelCardSlackSignIn(accountID: Int64) {
        slackAccountsViewModel?.cancelConnect(accountID: Int(accountID))
    }
}
