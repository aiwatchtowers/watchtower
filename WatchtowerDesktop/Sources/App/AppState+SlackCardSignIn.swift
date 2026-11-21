import Foundation

extension AppState {
    /// Cancel on an agent card's waiting Reconnect Slack: ends the built-in
    /// sign-in the card started (`reconnectSlack`), silently. Named apart from
    /// `SlackConnectionDetail`'s `cancelSlackReconnect`, which cancels the
    /// legacy workspace reconnect.
    func cancelCardSlackSignIn() {
        slackAccountsViewModel?.cancelConnect()
    }
}
