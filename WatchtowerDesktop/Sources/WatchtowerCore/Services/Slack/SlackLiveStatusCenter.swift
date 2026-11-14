import Foundation
import GRDB
import Observation

/// One `slack_live_status` row: the Live probe's verdict for a workspace
/// (`teamID` "" = not identified) and provider.
package struct SlackLiveStatusRow: Equatable, Sendable {
    package let teamID: String
    package let provider: String
    package let status: String
    package let errorClass: String
    package let connectorID: String
    package let checkedAt: String
}

/// Runs `watchtower slack live probe` for each provider, one at a time and
/// never twice at once, and mirrors `slack_live_status` for the UI. The
/// probe makes a real Slack read through the user's Claude / Codex
/// connector, so it is cheap to ask again but slow to run (seconds).
@MainActor
@Observable
package final class SlackLiveStatusCenter {
    package private(set) var statuses: [SlackLiveStatusRow] = []
    package private(set) var isRunning = false
    /// The pass in flight; tests await it.
    package private(set) var inFlight: Task<Void, Never>?

    @ObservationIgnored private var lastPass: Date?
    private let dbPool: DatabasePool
    private let runner: CLIRunnerProtocol?
    private let providers: [String]
    private let now: () -> Date

    package init(
        dbPool: DatabasePool,
        runner: CLIRunnerProtocol?,
        providers: [String] = ["claude", "codex"],
        now: @escaping () -> Date = Date.init
    ) {
        self.dbPool = dbPool
        self.runner = runner
        self.providers = providers
        self.now = now
    }

    /// Probes unless a pass started within `maxAge` seconds or one is
    /// running. The CLI repeats the age check per provider (`--if-older`).
    package func refreshIfStale(maxAge: TimeInterval = 600) {
        guard !isRunning else { return }
        if let lastPass, now().timeIntervalSince(lastPass) < maxAge { return }
        start(ifOlder: maxAge)
    }

    /// The "Check again" button: probes now, whatever the last verdict's age.
    package func checkAgain() {
        guard !isRunning else { return }
        start(ifOlder: nil)
    }

    package func reload() async {
        let rows = (try? await dbPool.read { db in
            let fetched = try Row.fetchAll(db, sql: """
                SELECT team_id, provider, status, error_class, connector_id, checked_at
                FROM slack_live_status ORDER BY checked_at DESC, team_id, provider
                """)
            return fetched.map { row in
                SlackLiveStatusRow(
                    teamID: row["team_id"], provider: row["provider"], status: row["status"],
                    errorClass: row["error_class"], connectorID: row["connector_id"],
                    checkedAt: row["checked_at"])
            }
        }) ?? []
        if rows != statuses { statuses = rows }
    }

    private func start(ifOlder: TimeInterval?) {
        isRunning = true
        lastPass = now()
        inFlight = Task { [weak self] in
            guard let self else { return }
            await self.runPass(ifOlder: ifOlder)
            self.isRunning = false
        }
    }

    private func runPass(ifOlder: TimeInterval?) async {
        for provider in providers {
            guard !Task.isCancelled, let runner else { break }
            var args = ["slack", "live", "probe", "--provider", provider, "--json"]
            if let ifOlder { args += ["--if-older", "\(Int(ifOlder))s"] }
            _ = try? await runner.run(args: args, timeout: 150)
            await reload()
        }
        await reload()
    }
}
