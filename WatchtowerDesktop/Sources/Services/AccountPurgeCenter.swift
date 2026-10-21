import Foundation
import GRDB
import Observation
import WatchtowerCore

/// Delivers an account purge notice; `NotificationService` in the app, a fake in tests.
protocol AccountPurgeNotifying {
    func sendAccountPurgeNotice(_ notice: AccountPurgeNotice)
}

extension NotificationService: AccountPurgeNotifying {}

/// The purge ledger as the app shows it (board #601): the open rows behind
/// the red lines on Settings → Connections and Home, the recently done ones,
/// one notification per row per state, and the switch's effective state from
/// `watchtower accounts purges --json`. The daemon writes `account_purges`
/// from another process, so GRDB observation never fires: a 30 s poll
/// re-reads it (the `PlanUsageCenter` shape).
@MainActor
@Observable
final class AccountPurgeCenter {
    static let pollInterval: Duration = .seconds(30)
    /// How long a done or failed purge stays listed (and its line shown).
    static let recentWindow: TimeInterval = 7 * 24 * 3600

    private(set) var openRows: [AccountPurge] = []
    private(set) var recentRows: [AccountPurge] = []
    /// nil until the CLI answered; also nil after a failed read.
    private(set) var status: AccountPurgeStatus?
    private(set) var statusError: String?

    @ObservationIgnored private var pollTask: Task<Void, Never>?
    private let dbPool: DatabasePool
    private let runner: CLIRunnerProtocol?
    private let notifier: AccountPurgeNotifying?
    private let defaults: UserDefaults
    private let now: () -> Date

    init(
        dbPool: DatabasePool,
        runner: CLIRunnerProtocol?,
        notifier: AccountPurgeNotifying? = nil,
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init
    ) {
        self.dbPool = dbPool
        self.runner = runner
        self.notifier = notifier
        self.defaults = defaults
        self.now = now
    }

    func start() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            await self?.reloadStatus()
            while !Task.isCancelled {
                guard let self else { return }
                await self.reload()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    func reload() async {
        let since = now().addingTimeInterval(-Self.recentWindow)
        do {
            let (open, recent) = try await dbPool.read { db in
                (try AccountPurgeQueries.open(db), try AccountPurgeQueries.recent(db, since: since))
            }
            guard !Task.isCancelled else { return }
            if open != openRows { openRows = open }
            if recent != recentRows { recentRows = recent }
            notify(open + recent)
        } catch {
            NSLog("AccountPurgeCenter: reload failed: %@", String(describing: error))
        }
    }

    /// Re-reads the switch from Go (`purge.Enabled`); Settings calls it on appear.
    func reloadStatus() async {
        guard let runner else { return }
        do {
            let data = try await runner.run(args: ["accounts", "purges", "--json"])
            status = try AccountPurgeStatus.decode(data)
            statusError = nil
        } catch {
            status = nil
            statusError = "Couldn't read the current state — see the log."
            NSLog("AccountPurgeCenter: accounts purges --json failed: %@", String(describing: error))
        }
    }

    /// The open purge of one account, for its red line.
    func openRow(source: String, accountID: Int64) -> AccountPurge? {
        openRows.first { $0.source == source && $0.accountID == accountID }
    }

    /// The account's latest done purge within the recent window.
    func doneRow(source: String, accountID: Int64) -> AccountPurge? {
        recentRows.first { $0.source == source && $0.accountID == accountID && $0.isDone }
    }

    /// A row counts as sent once it is handed to the notifier, even if
    /// notifications are denied (the `PlanUsageCenter` precedent); a pause
    /// holds it back with `sent` untouched.
    private func notify(_ rows: [AccountPurge]) {
        guard let notifier, !NotificationPreferences.isPaused(defaults) else { return }
        let sent = Set(defaults.stringArray(forKey: AccountPurgeNoticePolicy.sentKey) ?? [])
        let result = AccountPurgeNoticePolicy.notices(rows: rows, sent: sent)
        for notice in result.notices { notifier.sendAccountPurgeNotice(notice) }
        if result.sent != sent {
            defaults.set(result.sent.sorted(), forKey: AccountPurgeNoticePolicy.sentKey)
        }
    }
}
