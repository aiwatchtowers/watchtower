import Foundation

/// The revoked-calendar alert's **Reconnect** (#2132 G4): one Google sign-in
/// through `GoogleAccountsViewModel`, so it shares the Google busy flag and
/// the waiting line's Cancel with every other Google sign-in.
extension AppState {
    /// Re-consents the account the alert flagged (`authState.accountID`,
    /// N2: never the CLI's "account #1" alias when a specific account is
    /// broken). Only a flagged account the accounts read says is gone (or no
    /// flagged account) runs the legacy `calendar login --app-return`; an
    /// unread or failed read re-logs the flagged id. Either way Calendar
    /// opens, where the banner or the top line shows the wait.
    func reconnectGoogleCalendar(accountID: Int?) {
        selectedDestination = .calendar
        guard let vm = googleAccountsViewModel else { return }
        if GoogleConnectFlow.shared.isRunning {
            // Calendar's empty-state connect runs: one Google sign-in at a time.
            vm.error = GoogleAccountsViewModel.busyMessage
            return
        }
        guard let accountID else {
            vm.reloginLegacyCalendar(daemonPolicy: accountDaemonPolicy)
            return
        }
        if let account = vm.accounts.first(where: { $0.id == accountID }) {
            vm.relogin(account, daemonPolicy: accountDaemonPolicy)
        } else if vm.hasRead, vm.readError == nil {
            vm.reloginLegacyCalendar(daemonPolicy: accountDaemonPolicy)
        } else {
            vm.relogin(accountID: accountID, daemonPolicy: accountDaemonPolicy)
        }
    }
}
