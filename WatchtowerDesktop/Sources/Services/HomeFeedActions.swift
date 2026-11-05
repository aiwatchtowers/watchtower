import Foundation
import GRDB
import WatchtowerCore

/// Writes a feed row's Done / Hide to its source; `HomeCenter` hides the row
/// first and brings it back when this throws or returns false.
@MainActor
protocol HomeFeedPerforming {
    /// `contentHash` is an automation card's drawn version (`""` for every
    /// other kind). False: the card was rewritten or closed since it was
    /// drawn and nothing was written; the caller re-reads it.
    func perform(_ action: FeedAction, on ref: FeedRef, contentHash: String, now: Date, calendar: Calendar)
        async throws -> Bool
}

/// The production writes: inbox rows through the Go CLI (`inbox resolve` /
/// `inbox dismiss`), reminders, automation outputs (Done = `done_at`, Hide =
/// dismissed, both at the drawn content hash) and targets through GRDB, the same writes the Inbox, the
/// action strip and Targets make. Proposals and events have no
/// action on Home; a call for one does nothing.
///
/// "Already gone" is quiet: Go's `ResolveInboxItem` / `DismissInboxItem`
/// never check the rows they changed, so a missing or already closed item
/// exits 0 and reads as success here; a reminder or target deleted elsewhere
/// (`RowNotFoundError` / `TargetNotFoundError`) is success too, since the row
/// the owner wanted gone is gone. Every other failure is thrown.
@MainActor
final class LiveHomeFeedPerformer: HomeFeedPerforming {
    private let runner: (any CLIRunnerProtocol)?
    private let pool: DatabasePool

    init(runner: (any CLIRunnerProtocol)?, pool: DatabasePool) {
        self.runner = runner
        self.pool = pool
    }

    @discardableResult
    func perform(_ action: FeedAction, on ref: FeedRef, contentHash: String, now: Date, calendar: Calendar)
        async throws -> Bool {
        switch ref {
        case .inbox(let id):
            guard let runner else { throw HomeFeedActionError.cliUnavailable }
            _ = try await runner.run(
                args: ["inbox", action == .done ? "resolve" : "dismiss", "\(id)"], timeout: HomeFeedActionError.cliTimeout)
        case .reminder(let id):
            let until = ISO8601DateFormatter().string(from: Self.tomorrowNine(now: now, calendar: calendar))
            try await quietIfGone {
                try await self.pool.write { db in
                    switch action {
                    case .done: try ReminderQueries.markDone(db, id: id)
                    case .hide: try ReminderQueries.snooze(db, id: id, until: until)
                    }
                }
            }
        case .target(let id):
            let until = Self.tomorrowNine(now: now, calendar: calendar)
            try await quietIfGone {
                try await self.pool.write { db in
                    switch action {
                    case .done: try TargetQueries.updateStatus(db, id: id, status: "done")
                    case .hide: try TargetQueries.snooze(db, id: id, untilInstant: until)
                    }
                }
            }
        case .output(let id):
            // Only the version drawn: a living card rewritten meanwhile, or
            // one already closed elsewhere, changes nothing and is re-read.
            return try await pool.write { db in
                switch action {
                case .done: try AutomationQueries.markOutputDone(db, id: id, contentHash: contentHash, now: now)
                case .hide: try AutomationQueries.dismissOutput(db, id: id, contentHash: contentHash, now: now)
                }
            }
        case .proposal, .event:
            return true
        }
        return true
    }

    /// Tomorrow 09:00 in `calendar`'s time zone: where a hidden reminder or
    /// target comes back.
    static func tomorrowNine(now: Date, calendar: Calendar) -> Date {
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86_400)
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }

    private func quietIfGone(_ write: () async throws -> Void) async throws {
        do {
            try await write()
        } catch is RowNotFoundError {
            return
        } catch is TargetNotFoundError {
            return
        }
    }
}
