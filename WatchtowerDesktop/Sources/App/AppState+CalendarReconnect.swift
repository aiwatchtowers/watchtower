import Foundation

/// The revoked-calendar alert's **Reconnect** (#2132 G4): one Google sign-in
/// through `GoogleAccountsViewModel`, so it shares the Google busy flag and
/// the waiting line's Cancel with every other Google sign-in.
extension AppState {
    /// Re-consents the account the alert flagged (`authState.accountID`,
    /// N2: never the CLI's "account #1" alias when a specific account is
    /// broken). Only a flagged account a fresh accounts read says is gone (or
    /// no flagged account) runs the legacy `calendar login --app-return`; an
    /// unread or failed read re-logs the flagged id. Either way Calendar
    /// opens, where the banner or the top line shows the wait.
    ///
    /// Returns the re-read run when the flagged id is missing from the last
    /// read (it may predate the account): the decision waits for it. Nil when
    /// the decision was made at once.
    @discardableResult
    func reconnectGoogleCalendar(accountID: Int?) -> Task<Void, Never>? {
        selectedDestination = .calendar
        guard let vm = googleAccountsViewModel else { return nil }
        if GoogleConnectFlow.shared.isRunning {
            // Calendar's empty-state connect runs: one Google sign-in at a time.
            vm.refuseBusy(place: accountID.map { .account($0) } ?? .section)
            return nil
        }
        guard let accountID else {
            vm.reloginLegacyCalendar(daemonPolicy: accountDaemonPolicy)
            return nil
        }
        if let account = vm.accounts.first(where: { $0.id == accountID }) {
            vm.relogin(account, daemonPolicy: accountDaemonPolicy)
            return nil
        }
        guard vm.hasRead, vm.readError == nil else {
            vm.relogin(accountID: accountID, daemonPolicy: accountDaemonPolicy)
            return nil
        }
        // A good read without the account may be older than it: read again.
        return Task { [self] in
            let rows = await vm.refreshAsync(quiet: true)
            // Calendar's empty-state Connect may have started during the read
            // (the model's own sign-ins hit its busy guard below).
            if GoogleConnectFlow.shared.isRunning {
                vm.refuseBusy(place: .account(accountID))
                return
            }
            // This read's own answer: a concurrent refresh may have replaced
            // `accounts`/`readError` meanwhile.
            if let rows, let account = rows.first(where: { $0.id == accountID }) {
                vm.relogin(account, daemonPolicy: accountDaemonPolicy)
            } else if rows != nil {
                vm.reloginLegacyCalendar(daemonPolicy: accountDaemonPolicy)
            } else {
                vm.relogin(accountID: accountID, daemonPolicy: accountDaemonPolicy)
            }
        }
    }
}
