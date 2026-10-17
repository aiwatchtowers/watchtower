import Foundation

/// Failed automation runs the owner has not looked at (#584): the failure
/// share of the Automations sidebar badge and the macOS notices for runs
/// nobody started by hand.
///
/// Every input is the automation and its newest ended run that is not a dry
/// run (`AutomationQueries.newestEndedRuns`).
/// - **Badge:** an automation counts while that run failed (`failedStatuses`)
///   and the owner has not looked at its card since. Looking at the card
///   (the caller decides: tab visible, app active) or a newer run that did
///   not fail clears it.
/// - **Failure notice:** a schedule, catch-up or event run that failed posts
///   at most one notice per automation per `noticeInterval`; a failure inside
///   the window, a run ended by a daemon restart (`interrupted`), a run that
///   ended more than `noticeInterval` ago and a run that disabled its
///   automation (the disabled notice wins) count on the badge only. More
///   than `coalesceAbove` notices due in one pass become one
///   "N automations failed". Manual and button runs post none (the
///   quick-run finish notice covers the palette and the tray).
/// - **Disabled notice:** the daemon turned an automation off by itself
///   (`automations.disabled_at`, a runaway script): one "<name> was disabled"
///   per `disabled_at`, whatever started the run and however long ago; more
///   than `coalesceAbove` in one pass become one "N automations were disabled".
///
/// State is small maps in `UserDefaults`, keyed by workspace (the database
/// path) and automation id; entries of automations whose row is gone from
/// the database are pruned (a removed recipe's row stays, and so does its state).
@MainActor
package final class AutomationFailureWatch {
    nonisolated package static let failedStatuses: Set<AutomationRunStatus> = [.failed, .budgetExceeded, .timedOut, .expired]
    /// Runs nobody started by hand.
    nonisolated package static let backgroundTriggers: Set<String> = ["schedule", "catch_up", "event"]
    nonisolated package static let noticeInterval: TimeInterval = 24 * 60 * 60
    /// More failure notices than this in one pass post one summary instead.
    nonisolated package static let coalesceAbove = 2

    nonisolated static let seenKey = "automations.failures.seenRunID"
    nonisolated static let handledKey = "automations.failures.handledRunID"
    nonisolated static let noticeKey = "automations.failures.lastNoticeAt"
    nonisolated static let disabledKey = "automations.failures.disabledAt"

    private let defaults: UserDefaults
    private let workspace: String
    private let notifier: AutomationRunNotifying

    /// `workspace` scopes the stored state (the database path).
    package init(defaults: UserDefaults, workspace: String, notifier: AutomationRunNotifying) {
        self.defaults = defaults
        self.workspace = workspace
        self.notifier = notifier
    }

    /// `run` when it counts as a failure.
    nonisolated package static func failure(_ run: AutomationRun?) -> AutomationRun? {
        guard let run, run.trigger != "dry_run", failedStatuses.contains(run.status) else { return nil }
        return run
    }

    /// Automations whose newest ended run failed and was not seen.
    package func unseenCount(_ items: [AutomationListItem], runs: [Int64: AutomationRun]) -> Int {
        let seen = numbers(Self.seenKey, \.int64Value)
        return items.filter { item in
            guard let run = Self.failure(runs[item.id]) else { return false }
            return run.id > (seen[key(item.id)] ?? 0)
        }.count
    }

    /// The owner looked at the card of `automationID`: its newest ended run is seen.
    package func markSeen(_ automationID: Int64, runs: [Int64: AutomationRun]) {
        guard let run = runs[automationID] else { return }
        var seen = numbers(Self.seenKey, \.int64Value)
        guard run.id > (seen[key(automationID)] ?? 0) else { return }
        seen[key(automationID)] = run.id
        defaults.set(seen, forKey: Self.seenKey)
    }

    /// Posts the notices not posted yet and prunes the state of automations
    /// no longer listed.
    /// `existing` is every automation id in the database, removed recipes included.
    package func notify(
        _ items: [AutomationListItem],
        runs: [Int64: AutomationRun],
        existing: Set<Int64>,
        now: Date
    ) {
        var state = Ledger(
            handled: numbers(Self.handledKey, \.int64Value),
            notices: numbers(Self.noticeKey, \.doubleValue),
            disabled: numbers(Self.disabledKey, \.doubleValue)
        )
        let before = state
        var due: [(item: AutomationListItem, run: AutomationRun)] = []
        var disabled: [AutomationListItem] = []
        for item in items {
            if dueDisabled(item, state: &state) { disabled.append(item) }
            if let run = dueFailure(item, run: runs[item.id], now: now, state: &state) { due.append((item, run)) }
        }
        if disabled.count > Self.coalesceAbove {
            notifier.automationsDisabled(count: disabled.count)
        } else {
            for item in disabled {
                notifier.automationDisabled(name: Self.displayName(item.automation), reason: item.automation.disabledReason,
                                            automationID: item.id, runID: runs[item.id]?.id)
            }
        }
        if due.count > Self.coalesceAbove {
            notifier.automationsFailed(count: due.count)
        } else {
            for (item, run) in due {
                notifier.runFinished(name: Self.displayName(item.automation), status: run.status, summary: run.summary,
                                     error: run.error, automationID: item.id, runID: run.id)
            }
        }
        for (item, _) in due { state.notices[key(item.id)] = now.timeIntervalSince1970 }
        prune(&state, keeping: existing)
        save(state, before: before)
    }

    // MARK: - Private

    private struct Ledger: Equatable {
        var handled: [String: Int64]
        var notices: [String: Double]
        var disabled: [String: Double]
    }

    /// The automation's `disabled_at` was not notified yet.
    private func dueDisabled(_ item: AutomationListItem, state: inout Ledger) -> Bool {
        guard let at = item.automation.disabledAt?.timeIntervalSince1970,
              at > (state.disabled[key(item.id)] ?? 0) else { return false }
        state.disabled[key(item.id)] = at
        return true
    }

    /// The run's failure notice is due: a background failure not handled
    /// yet, recent, not a restart, that did not disable its automation,
    /// outside the automation's daily window.
    private func dueFailure(_ item: AutomationListItem, run: AutomationRun?, now: Date, state: inout Ledger)
        -> AutomationRun? {
        guard let run = Self.failure(run), Self.backgroundTriggers.contains(run.trigger),
              run.id > (state.handled[key(item.id)] ?? 0) else { return nil }
        state.handled[key(item.id)] = run.id
        guard run.errorKind != "interrupted", !Self.disabledItsAutomation(run, item.automation),
              let finished = run.finishedAt, now.timeIntervalSince(finished) < Self.noticeInterval else { return nil }
        if let last = state.notices[key(item.id)],
           now.timeIntervalSince(Date(timeIntervalSince1970: last)) < Self.noticeInterval { return nil }
        return run
    }

    private func prune(_ state: inout Ledger, keeping ids: Set<Int64>) {
        let kept = Set(ids.map(key))
        let prefix = workspace + "|"
        func gone(_ name: String) -> Bool { name.hasPrefix(prefix) && !kept.contains(name) }
        state.handled = state.handled.filter { !gone($0.key) }
        state.notices = state.notices.filter { !gone($0.key) }
        state.disabled = state.disabled.filter { !gone($0.key) }
        var seen = numbers(Self.seenKey, \.int64Value)
        let count = seen.count
        seen = seen.filter { !gone($0.key) }
        if seen.count != count { defaults.set(seen, forKey: Self.seenKey) }
    }

    private func save(_ state: Ledger, before: Ledger) {
        if state.handled != before.handled { defaults.set(state.handled, forKey: Self.handledKey) }
        if state.notices != before.notices { defaults.set(state.notices, forKey: Self.noticeKey) }
        if state.disabled != before.disabled { defaults.set(state.disabled, forKey: Self.disabledKey) }
    }

    /// The daemon disabled `a` during or after `run` (QuickRunCenter's rule too).
    nonisolated package static func disabledItsAutomation(_ run: AutomationRun, _ a: Automation) -> Bool {
        guard let at = a.disabledAt else { return false }
        return at >= (run.startedAt ?? run.queuedAt ?? .distantPast)
    }

    nonisolated private static func displayName(_ a: Automation) -> String {
        a.name.isEmpty ? a.slug : a.name
    }

    private func key(_ id: Int64) -> String { "\(workspace)|\(id)" }

    private func numbers<T>(_ name: String, _ value: (NSNumber) -> T) -> [String: T] {
        (defaults.dictionary(forKey: name) as? [String: NSNumber])?.mapValues(value) ?? [:]
    }
}
