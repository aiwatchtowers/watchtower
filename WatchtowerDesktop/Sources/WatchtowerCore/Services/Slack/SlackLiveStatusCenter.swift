import Foundation
import GRDB
import Observation
import os

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
///
/// `statuses`, `lastError` and `checkAgain()` have no screen yet: the Slack
/// Live screens (plan B of the spec) read them; until then only
/// `refreshIfStale()` runs, from Connections → Slack.
@MainActor
@Observable
package final class SlackLiveStatusCenter {
    private static let log = Logger(subsystem: "com.watchtower.desktop", category: "slack-live")

    package private(set) var statuses: [SlackLiveStatusRow] = []
    /// The last failure — a status read or a probe run — kept for display;
    /// `nil` after a clean read. A failed read keeps the rows last shown
    /// (it is not "no rows").
    package private(set) var lastError: String?
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
        let rows: [SlackLiveStatusRow]
        do {
            rows = try await dbPool.read { db -> [SlackLiveStatusRow] in
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
            }
        } catch {
            Self.log.error("reading slack_live_status: \(error.localizedDescription, privacy: .public)")
            lastError = "Could not read the Live Slack status: \(error.localizedDescription)"
            return
        }
        lastError = nil
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
            var probeError: String?
            do {
                _ = try await runner.run(args: args, timeout: 150)
            } catch {
                Self.log.error("slack live probe \(provider, privacy: .public): \(error.localizedDescription, privacy: .public)")
                probeError = "The \(provider) Live Slack check failed: \(error.localizedDescription)"
            }
            await reload()
            if let probeError { lastError = probeError }
        }
        if runner == nil { await reload() }
    }
}
