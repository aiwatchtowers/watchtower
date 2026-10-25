import GRDB
import WatchtowerCore

extension AppState {
    /// The account purge ledger: the previous center stopped, a new one polling.
    func initAccountPurges(dbPool: DatabasePool, cliRunner: (any CLIRunnerProtocol)?) {
        accountPurgeCenter?.stop()
        let center = AccountPurgeCenter(dbPool: dbPool, runner: cliRunner, notifier: NotificationService.shared)
        accountPurgeCenter = center
        center.start()
    }

    /// Reconnect from a purge notice (Home's banner, a notification click):
    /// the Connections tab on the account's source.
    func openAccountConnection(source: String) {
        openConnections(ConnectionService(rawValue: source))
    }
}
