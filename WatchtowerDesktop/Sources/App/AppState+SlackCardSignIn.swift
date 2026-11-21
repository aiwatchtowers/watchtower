import Foundation

extension AppState {
    /// An agent card's Reconnect Slack waiting line for `accountID`: present
    /// while a card's sign-in for that account runs (read from the accounts
    /// view model, so a card drawn again mid-sign-in shows it too), its Cancel
    /// bound to that attempt. Nil when none runs.
    func cardSlackSignInWait(accountID: Int64) -> MacAgentActionCard.SlackSignInWait? {
        guard let attempt = slackAccountsViewModel?.cardAttempt(forAccount: Int(accountID)) else { return nil }
        return MacAgentActionCard.SlackSignInWait(copy: .slack) { [weak self] in
            self?.cancelCardSlackSignIn(attempt: attempt)
        }
    }

    /// Cancel on an agent card's waiting Reconnect Slack: ends attempt
    /// `attempt`, the one a card began (`reconnectSlack`), silently, and no
    /// other Slack sign-in. Named apart from `SlackConnectionDetail`'s
    /// `cancelSlackReconnect`, which cancels the legacy workspace reconnect.
    func cancelCardSlackSignIn(attempt: Int) {
        slackAccountsViewModel?.cancelCardSignIn(attempt: attempt)
    }
}
