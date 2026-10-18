import Foundation
import GRDB

/// The Inbox action strip — a union of pending agent-action proposals, due
/// reminders and unread automation inbox outputs (STRIP-01 amended, spec
/// §14.4). AppState-owned so it
/// survives navigation away from the Dashboard (the `SlackAccountsViewModel`
/// house pattern): `refresh()` on appear / after a mutation, not live GRDB
/// observation — cross-process daemon/CLI writes don't fire `ValueObservation`
/// (`AgentActionFeed`'s doc comment explains why).
///
/// Composes `AgentActionFeed` rather than reimplementing its CLI plumbing —
/// approve/reject/retry route through it, so `Registry.Apply`'s exactly-once
/// claim and the envelope-error surfacing stay in one place. Reminder
/// done/snooze are direct GRDB writes (Swift-owned, no daemon contention,
/// the `inbox_feedback` dual-path precedent), so they need no CLI round trip;
/// so are an output's Done/Dismiss, the only automation columns Swift writes
/// (`read_at`/`dismissed_at`, spec §9.6). They await the writer off the main
/// thread (board #670): one write per card at a time, and the card leaves
/// the strip only once its write landed.
@MainActor
@Observable
package final class ActionStripViewModel {
    package private(set) var actionRows: [AgentAction] = []
    package private(set) var reminderRows: [Reminder] = []
    /// Unread `kind='inbox'` automation outputs, newest first.
    package private(set) var outputRows: [AutomationOutputCard] = []
    /// Action id → "⚙ <automation> · run #<n>" for the rows an automation
    /// run proposed (`context_type='automation_run'`).
    package private(set) var actionLabels: [Int64: String] = [:]
    /// `finished_at` of the latest successful `reaction-commands` daemon run
    /// — the cheat sheet's "last check". Nil until the phase has run once.
    package private(set) var lastReactionCheck: String?
    package var lastError: String?

    private let dbPool: DatabasePool
    /// One write per card (board #670).
    private let pendingWrites = PendingWrites()
    /// Exposed so a view can reuse its `inFlight`/card helpers if it ever
    /// needs to render one of these rows the way a chat surface does.
    package let actionFeed: AgentActionFeed

    package init(
        dbPool: DatabasePool,
        cliRunner: CLIRunnerProtocol? = nil,
        automationsWake: (() async throws -> Void)? = nil
    ) {
        self.dbPool = dbPool
        self.actionFeed = AgentActionFeed(dbPool: dbPool, cliRunner: cliRunner, automationsWake: automationsWake)
    }

    /// The Inbox sidebar badge: what the strip waits on the owner for —
    /// proposals awaiting a decision, due reminders and unread inbox outputs.
    /// Each source tolerates a schema that predates it (its table missing
    /// counts 0); any other read error is thrown, never folded into 0.
    nonisolated package static func badgeCount(_ db: Database, nowUTC: String) throws -> Int {
        try zeroIfTableMissing { try AgentActionQueries.awaitingOwnerCount(db) }
            + zeroIfTableMissing { try ReminderQueries.dueCount(db, nowUTC: nowUTC) }
            + zeroIfTableMissing { try AutomationQueries.inboxOutputCount(db) }
    }

    /// `count()`, or 0 when its table does not exist yet (an older schema).
    nonisolated package static func zeroIfTableMissing(_ count: () throws -> Int) throws -> Int {
        do {
            return try count()
        } catch let error as DatabaseError
            where error.resultCode == .SQLITE_ERROR && (error.message ?? "").hasPrefix("no such table") {
            return 0
        }
    }

    /// The card labels for `rows`: an automation run's row gets its run's
    /// label, or "⚙ automation · run #<n>" when the run (and with it the
    /// automation) is gone. Other rows get none.
    nonisolated package static func labels(for rows: [AgentAction], runLabels: [Int64: String]) -> [Int64: String] {
        var out: [Int64: String] = [:]
        for row in rows {
            guard let runID = automationRunID(row) else { continue }
            out[row.id] = runLabels[runID] ?? "⚙ automation · run #\(runID)"
        }
        return out
    }

    /// The run an automation row was proposed by; nil for any other row.
    nonisolated package static func automationRunID(_ row: AgentAction) -> Int64? {
        guard row.contextType == AgentActionFeed.automationRunContext else { return nil }
        return Int64(row.contextID)
    }

    /// One-shot refetch of the strip's three sources (plus the automation
    /// labels and the reaction phase's last check). The only thing that can
    /// surface a row a subprocess (CLI action commands, the reaction-command
    /// daemon phase, an automation run) wrote. Reads only (STRIP-02).
    package func refresh() {
        lastError = nil
        let formatter = ISO8601DateFormatter()
        let now = formatter.string(from: Date())
        let terminalSince = formatter.string(from: Date().addingTimeInterval(-24 * 3600))
        do {
            let snapshot = try dbPool.read { db in
                let actions = try AgentActionQueries.fetchStrip(db, terminalSince: terminalSince)
                let runLabels = try AutomationQueries.runLabels(db, runIDs: actions.compactMap(Self.automationRunID))
                return (
                    actions: actions,
                    labels: Self.labels(for: actions, runLabels: runLabels),
                    reminders: try ReminderQueries.fetchDue(db, nowUTC: now),
                    outputs: try AutomationQueries.fetchInboxOutputs(db),
                    lastCheck: try PipelineRunQueries.lastSuccessfulFinish(db, pipeline: "reaction-commands")
                )
            }
            actionRows = snapshot.actions
            actionLabels = snapshot.labels
            reminderRows = snapshot.reminders
            outputRows = snapshot.outputs
            lastReactionCheck = snapshot.lastCheck
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// A reminder's Done or Snooze is being written: its buttons wait.
    package func isWriting(reminder id: Int64) -> Bool {
        pendingWrites.isPending(CardKey.reminder(id))
    }

    /// An output's Done or Dismiss is being written: its buttons wait.
    package func isWriting(output id: Int64) -> Bool {
        pendingWrites.isPending(CardKey.output(id))
    }

    package func markReminderDone(_ id: Int64) async {
        await write(.reminder(id)) { try ReminderQueries.markDone($0, id: id) }
    }

    package func snoozeReminder(_ id: Int64, until: String) async {
        await write(.reminder(id), { try ReminderQueries.snooze($0, id: id, until: until) }, onFailure: { error in
            // A reminder deleted elsewhere leaves the strip; `refresh` clears
            // `lastError`, so the reason is set after it.
            if error is RowNotFoundError { self.refresh() }
        })
    }

    /// Done on an output card: writes `read_at` only. The card leaves the
    /// strip only once the write landed; a failure keeps it and says why.
    package func markOutputDone(_ id: Int64) async {
        let now = Date()
        await write(.output(id)) { try AutomationQueries.markOutputRead($0, id: id, now: now) }
    }

    /// Dismiss on an output card: writes `dismissed_at` only.
    package func dismissOutput(_ id: Int64) async {
        let now = Date()
        await write(.output(id)) { try AutomationQueries.dismissOutput($0, id: id, now: now) }
    }

    private enum CardKey: Hashable {
        case reminder(Int64)
        case output(Int64)
    }

    /// One write per card: a second press while it waits does nothing.
    private func write(
        _ key: CardKey,
        _ change: @escaping @Sendable (Database) throws -> Void,
        onFailure: (Error) -> Void = { _ in }
    ) async {
        let pool = dbPool
        await pendingWrites.run(key) {
            lastError = nil
            do {
                try await pool.write(change)
                refresh()
            } catch {
                onFailure(error)
                lastError = error.localizedDescription
            }
        }
    }

    package func approve(_ id: Int64, shownArgs: String, patch: String? = nil) async {
        await actionFeed.approve(id, shownArgs: shownArgs, patch: patch)
        refresh()
        adoptFeedError()
    }

    package func reject(_ id: Int64) async {
        await actionFeed.reject(id)
        refresh()
        adoptFeedError()
    }

    package func retry(_ id: Int64) async {
        await actionFeed.retry(id)
        refresh()
        adoptFeedError()
    }

    package func dismiss(_ id: Int64) async {
        await actionFeed.dismiss(id)
        refresh()
        adoptFeedError()
    }

    /// `actionFeed.lastError` carries only feed-wide failures (a row's own
    /// failure lives in `rowErrors`, on its card); a bare "call it and move
    /// on" would swallow that from anything observing only the strip's own
    /// `lastError`. Runs AFTER
    /// `refresh()`, which clears `lastError` on entry — otherwise refresh's
    /// own reset would immediately wipe the error this just adopted. Synced
    /// unconditionally when `refresh()` itself succeeded (not just when
    /// non-nil): a later successful call where the feed's own error cleared
    /// back to nil must clear the strip's copy too, not leave it stuck on a
    /// stale failure. Guarded on `lastError == nil` so a genuine `refresh()`
    /// read failure (the strip's own DB read, unrelated to the feed) is never
    /// overwritten by a stale/absent feed error.
    private func adoptFeedError() {
        guard lastError == nil else { return }
        lastError = actionFeed.lastError
    }
}
