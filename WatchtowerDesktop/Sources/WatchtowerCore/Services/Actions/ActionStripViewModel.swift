import Foundation
import GRDB

/// The Dashboard's action strip — a union of pending agent-action proposals
/// and due reminders, both reaction-command surfaces. AppState-owned so it
/// survives navigation away from the Dashboard (the `SlackAccountsViewModel`
/// house pattern): `refresh()` on appear / after a mutation, not live GRDB
/// observation — cross-process daemon/CLI writes don't fire `ValueObservation`
/// (`AgentActionFeed`'s doc comment explains why).
///
/// Composes `AgentActionFeed` rather than reimplementing its CLI plumbing —
/// approve/reject/retry route through it, so `Registry.Apply`'s exactly-once
/// claim and the envelope-error surfacing stay in one place. Reminder
/// done/snooze are direct GRDB writes (Swift-owned, no daemon contention,
/// the `inbox_feedback` dual-path precedent), so they need no CLI round trip.
@MainActor
@Observable
package final class ActionStripViewModel {
    package private(set) var actionRows: [AgentAction] = []
    package private(set) var reminderRows: [Reminder] = []
    package var lastError: String?

    private let dbPool: DatabasePool
    /// Exposed so a view can reuse its `inFlight`/card helpers if it ever
    /// needs to render one of these rows the way a chat surface does.
    package let actionFeed: AgentActionFeed

    package init(dbPool: DatabasePool, cliRunner: CLIRunnerProtocol? = nil) {
        self.dbPool = dbPool
        self.actionFeed = AgentActionFeed(dbPool: dbPool, cliRunner: cliRunner)
    }

    /// One-shot refetch of both halves of the strip. The only thing that can
    /// surface a row a subprocess (CLI action commands, the reaction-command
    /// daemon phase) wrote.
    package func refresh() {
        lastError = nil
        let formatter = ISO8601DateFormatter()
        let now = formatter.string(from: Date())
        let terminalSince = formatter.string(from: Date().addingTimeInterval(-24 * 3600))
        do {
            (actionRows, reminderRows) = try dbPool.read { db in
                (try AgentActionQueries.fetchStrip(db, terminalSince: terminalSince), try ReminderQueries.fetchDue(db, nowUTC: now))
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    package func markReminderDone(_ id: Int64) {
        lastError = nil
        do {
            try dbPool.write { try ReminderQueries.markDone($0, id: id) }
            refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    package func snoozeReminder(_ id: Int64, until: String) {
        lastError = nil
        do {
            try dbPool.write { try ReminderQueries.snooze($0, id: id, until: until) }
            refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    package func approve(_ id: Int64) async {
        await actionFeed.approve(id)
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

    /// `actionFeed` tracks its own `lastError` (envelope errors, process
    /// failures); a bare "call it and move on" would swallow that from
    /// anything observing only the strip's own `lastError`. Runs AFTER
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
