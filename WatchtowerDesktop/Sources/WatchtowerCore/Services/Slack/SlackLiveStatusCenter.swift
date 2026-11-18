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

    package init(
        teamID: String, provider: String, status: String, errorClass: String, connectorID: String, checkedAt: String
    ) {
        self.teamID = teamID
        self.provider = provider
        self.status = status
        self.errorClass = errorClass
        self.connectorID = connectorID
        self.checkedAt = checkedAt
    }
}

/// The center's last failure, kept as a value so the screen can name the
/// provider ("Claude", not the CLI's `claude`) and pick its actions
/// (`SlackModePresentation`): a failed probe keeps **Check again**, a failed
/// status read offers **Try again**.
package struct SlackLiveError: Equatable, Sendable {
    package enum Kind: Equatable, Sendable { case probe, read }

    /// The CLI provider (`claude`, `codex`) of a probe; "" for a read.
    package let provider: String
    package let message: String
    package let kind: Kind

    package init(provider: String, message: String, kind: Kind) {
        self.provider = provider
        self.message = message
        self.kind = kind
    }
}

/// Runs `watchtower slack live probe` for each provider, one at a time and
/// never twice at once, and mirrors `slack_live_status` for the UI. The
/// probe makes a real Slack read through the user's Claude / Codex
/// connector, so it is cheap to ask again but slow to run (seconds).
/// Connections → Slack shows it through `SlackModePresentation`.
@MainActor
@Observable
package final class SlackLiveStatusCenter {
    private static let log = Logger(subsystem: "com.watchtower.desktop", category: "slack-live")

    package private(set) var statuses: [SlackLiveStatusRow] = []
    /// The last failure — a status read or a probe run — kept for display.
    /// A failed read keeps the rows last shown (it is not "no rows"); a clean
    /// read clears a read failure. A probe failure lasts until the next pass
    /// starts, so the next provider's clean read does not hide it.
    package private(set) var lastError: SlackLiveError?
    /// The first `reload()` finished (read or failed): the block leaves its
    /// loading state.
    package private(set) var hasRead = false
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
            lastError = SlackLiveError(provider: "", message: error.localizedDescription, kind: .read)
            hasRead = true
            return
        }
        if lastError?.kind == .read { lastError = nil }
        hasRead = true
        if rows != statuses { statuses = rows }
    }

    private func start(ifOlder: TimeInterval?) {
        isRunning = true
        lastPass = now()
        lastError = nil
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
            var probeError: SlackLiveError?
            do {
                _ = try await runner.run(args: args, timeout: 150)
            } catch {
                Self.log.error("slack live probe \(provider, privacy: .public): \(error.localizedDescription, privacy: .public)")
                probeError = SlackLiveError(provider: provider, message: error.localizedDescription, kind: .probe)
            }
            await reload()
            // A read failure after the probe wins: the rows on screen are stale.
            if let probeError, lastError?.kind != .read { lastError = probeError }
        }
        if runner == nil { await reload() }
    }
}
