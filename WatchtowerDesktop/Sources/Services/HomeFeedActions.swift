import Foundation
import GRDB
import WatchtowerCore

/// Writes a feed row's Done / Hide to its source; `HomeCenter` hides the row
/// first and brings it back when this throws.
@MainActor
protocol HomeFeedPerforming {
    func perform(_ action: FeedAction, on ref: FeedRef, now: Date, calendar: Calendar) async throws
}

/// Why a feed action could not run at all.
enum HomeFeedActionError: LocalizedError, Equatable {
    /// The `watchtower` binary was not found: inbox rows are written by the CLI.
    case cliUnavailable
    /// No database is open yet.
    case databaseUnavailable

    var errorDescription: String? {
        switch self {
        case .cliUnavailable: "The command line is not available."
        case .databaseUnavailable: "The database is not open."
        }
    }
}

/// The production writes: inbox rows through the Go CLI (`inbox resolve` /
/// `inbox dismiss`), reminders, automation outputs (Done = read, Hide =
/// dismissed) and targets through GRDB, the same writes the Inbox, the
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

    func perform(_ action: FeedAction, on ref: FeedRef, now: Date, calendar: Calendar) async throws {
        switch ref {
        case .inbox(let id):
            guard let runner else { throw HomeFeedActionError.cliUnavailable }
            _ = try await runner.run(
                args: ["inbox", action == .done ? "resolve" : "dismiss", "\(id)"], timeout: Self.cliTimeout)
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
            // Already read or dismissed elsewhere: the update changes nothing, which is success.
            try await pool.write { db in
                switch action {
                case .done: try AutomationQueries.markOutputRead(db, id: id, now: now)
                case .hide: try AutomationQueries.dismissOutput(db, id: id, now: now)
                }
            }
        case .proposal, .event:
            return
        }
    }

    /// How long an inbox CLI call may run; past it the call throws and the
    /// row comes back with the error.
    static let cliTimeout: TimeInterval = 30

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
