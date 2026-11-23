import AppKit
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

    /// A Slack Remove or Disconnect dialog's message: the switch and notice
    /// from the organization's policy, the owner's saved setting and Go's
    /// status (`AccountPurgeStatus.removeDialogMessage`).
    func slackRemoveDialogMessage(_ label: String) -> String {
        AccountPurgeStatus.removeDialogMessage(
            slackAccount: label, status: accountPurgeCenter?.status,
            policy: managedPolicy.policy, setting: sharedConfig.diskPurgeRevokedData
        )
    }

    /// A Jira or Linear Remove dialog's message, `kept` first; the inputs as
    /// in `slackRemoveDialogMessage`.
    func removeDialogMessage(_ kept: String) -> String {
        AccountPurgeStatus.removeDialogMessage(
            kept, status: accountPurgeCenter?.status,
            policy: managedPolicy.policy, setting: sharedConfig.diskPurgeRevokedData
        )
    }

    /// Re-reads Go's purge status as a Remove or Disconnect dialog opens, so
    /// its notice follows a policy changed since Settings last read it.
    func refreshAccountPurgeStatus() {
        Task { await accountPurgeCenter?.reloadStatus() }
    }

    /// Reconnect from a purge notice (Home's banner, a notification click):
    /// the Connections tab on the account's source, in a main window brought
    /// forward (a click on the notice may come with only Settings or the
    /// tray open). `windows` and `activate` are `bringMainWindowForward`'s
    /// test seams.
    func openAccountConnection(
        source: String,
        windows: [NSWindow]? = nil,
        activate: () -> Void = ActivationPolicyDecision.becomeRegularAndActivate
    ) {
        bringMainWindowForward(windows: windows, activate: activate)
        openConnections(ConnectionService(rawValue: source))
    }
}
