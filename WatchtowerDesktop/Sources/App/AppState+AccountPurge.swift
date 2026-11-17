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

    /// FileVault's state now and on every activation (a user who turns it on
    /// in System Settings comes back to the app).
    func watchFileVault(status: FileVaultStatus = .live) {
        Task { [weak self] in
            self?.fileVaultState = await status.read()
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                guard let self else { return }
                self.fileVaultState = await status.read()
            }
        }
    }
}
