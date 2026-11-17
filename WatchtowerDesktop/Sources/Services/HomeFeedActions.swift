import Foundation
import WatchtowerCore
import WatchtowerInterface

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
/// `inbox dismiss`); reminders, automation outputs (Done = `done_at`, Hide =
/// dismissed, both at the drawn content hash) and targets through the
/// tower (`reminders.*`, `outputs.*`, `targets.*`, #1170 Task 12) — the same
/// Go writes the Inbox and Targets make. Proposals and events have no action
/// on Home; a call for one does nothing.
///
/// Each press's key is its row and action, so pressing Done again after a
/// failure with no answer re-sends the same request_id (a first send that
/// landed is answered from the ledger, never applied twice).
///
/// "Already gone" is quiet: Go's `ResolveInboxItem` / `DismissInboxItem`
/// never check the rows they changed, so a missing or already closed item
/// exits 0 and reads as success here; a reminder or target deleted elsewhere
/// (refused `not_found`) is success too,
/// since the row the owner wanted gone is gone. Every other failure is
/// thrown with the tower's sentence.
@MainActor
final class LiveHomeFeedPerformer: HomeFeedPerforming {
    private let runner: (any CLIRunnerProtocol)?
    private let tower: (any TowerSending)?

    init(runner: (any CLIRunnerProtocol)?, tower: (any TowerSending)?) {
        self.runner = runner
        self.tower = tower
    }

    @discardableResult
    func perform(_ action: FeedAction, on ref: FeedRef, contentHash: String, now: Date, calendar: Calendar)
        async throws -> Bool {
        let key = "home|\(ref)|\(action)"
        switch ref {
        case .inbox(let id):
            guard let runner else { throw HomeFeedActionError.cliUnavailable }
            _ = try await runner.run(
                args: ["inbox", action == .done ? "resolve" : "dismiss", "\(id)"], timeout: HomeFeedActionError.cliTimeout)
        case .reminder(let id):
            // As the Inbox's Done/Snooze, Go also queues Needs approval's redraw.
            let until = ISO8601DateFormatter().string(from: Self.tomorrowNine(now: now, calendar: calendar))
            let command: TowerCommand = action == .done ? .remindersDone : .remindersSnooze
            let _: ActResult? = try await send(command, key: key, quietIfGone: true) {
                ReminderWriteRequest(requestID: $0, id: id, until: action == .done ? nil : until)
            }
        case .target(let id):
            switch action {
            case .done:
                let _: TargetStatusResult? = try await send(.targetsSetStatus, key: key, quietIfGone: true) {
                    TargetStatusRequest(requestID: $0, id: Int64(id), status: "done")
                }
            case .hide:
                let until = Self.snoozeInstant(Self.tomorrowNine(now: now, calendar: calendar))
                let _: TargetStatusResult? = try await send(.targetsSnooze, key: key, quietIfGone: true) {
                    TargetSnoozeRequest(requestID: $0, id: Int64(id), until: until)
                }
            }
        case .output(let id):
            // Only the version drawn: a living card rewritten meanwhile, or
            // one already closed elsewhere, changes nothing and is re-read.
            let command: TowerCommand = action == .done ? .outputsDone : .outputsDismiss
            let result: ActResult? = try await send(command, key: key, quietIfGone: false) {
                OutputMarkRequest(requestID: $0, id: id, contentHash: contentHash)
            }
            return result?.already != true
        case .proposal, .event:
            return true
        }
        return true
    }

    /// Home's Hide of a target: `snooze_until` holds the instant as a UTC
    /// "yyyy-MM-ddTHH:mm" minute, the form Go's `UnsnoozeExpiredTargets`
    /// compares against, so the target comes back at that instant.
    static func snoozeInstant(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return fmt.string(from: date)
    }

    /// One press through the tower (`TowerSending.perform` under the row's
    /// key); nil when Go refused it `not_found` and that is quiet.
    private func send<Resp: Decodable & Sendable, Params: Encodable & Sendable>(
        _ command: TowerCommand, key: String, quietIfGone: Bool, _ params: (String) -> Params
    ) async throws -> Resp? {
        guard let tower else { throw TowerWriteError(TowerText.daemonDown) }
        do {
            return try await tower.perform(command, key: key, params)
        } catch let error as TowerWriteError where quietIfGone && error.isGone {
            return nil
        }
    }

    /// Tomorrow 09:00 in `calendar`'s time zone: where a hidden reminder or
    /// target comes back.
    static func tomorrowNine(now: Date, calendar: Calendar) -> Date {
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86_400)
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }
}
