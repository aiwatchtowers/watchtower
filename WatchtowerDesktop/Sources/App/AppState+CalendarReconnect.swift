import Foundation

/// The revoked-calendar alert's **Reconnect** (#2132 G4): one Google sign-in
/// through `GoogleAccountsViewModel`, so it shares the Google busy flag and
/// the waiting line's Cancel with every other Google sign-in.
extension AppState {
    /// Re-consents the account the alert flagged (`authState.accountID`,
    /// N2: never the CLI's "account #1" alias when a specific account is
    /// broken) when it still exists, otherwise runs the legacy
    /// `calendar login --app-return`. Either way Calendar opens, where the
    /// banner or the top line shows the wait.
    func reconnectGoogleCalendar(accountID: Int?) {
        selectedDestination = .calendar
        guard let vm = googleAccountsViewModel else { return }
        if let accountID, let account = vm.accounts.first(where: { $0.id == accountID }) {
            vm.relogin(account, daemonPolicy: accountDaemonPolicy)
        } else {
            vm.reloginLegacyCalendar(daemonPolicy: accountDaemonPolicy)
        }
    }
}
