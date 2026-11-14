import GRDB
import WatchtowerCore

extension AppState {
    /// The Slack Live probe's status mirror, rebuilt with the database.
    func initSlackLive(dbPool: DatabasePool, cliRunner: (any CLIRunnerProtocol)?) {
        let center = SlackLiveStatusCenter(dbPool: dbPool, runner: cliRunner)
        slackLiveStatusCenter = center
        Task { await center.reload() }
    }
}
