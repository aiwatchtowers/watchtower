import Foundation

/// Failed automation runs the owner has not looked at (#584): the failure
/// share of the Automations sidebar badge and the macOS notice for a run
/// nobody started by hand.
///
/// - **Badge:** an automation counts while its newest ended run failed
///   (`failedStatuses`, dry runs aside) and the owner has not opened its card
///   since that run ended. Opening the card (the tab visible with it
///   selected) or a newer run that did not fail clears it.
/// - **Notice:** a schedule, catch-up or event run that failed posts at most
///   one notice per automation per `noticeInterval`; later failures inside
///   that window only count on the badge. A run that disabled its automation
///   (Go appends `disabledMarker` to its error) always posts, whatever
///   started it. Manual and button runs post nothing else here: the quick-run
///   finish notice covers the palette and the tray, and both notices share
///   one identifier per run, so the disabled notice replaces a quick-run one.
/// - Only a run that ended within `noticeInterval` notifies, so failures
///   older than a day (an upgrade, a long quit) reach the badge only.
///
/// State is three small maps in `UserDefaults`, keyed by automation id (run
/// ids are never reused).
@MainActor
package final class AutomationFailureWatch {
    nonisolated package static let failedStatuses: Set<AutomationRunStatus> = [.failed, .budgetExceeded, .timedOut, .expired]
    /// Runs nobody started by hand.
    nonisolated package static let backgroundTriggers: Set<String> = ["schedule", "catch_up", "event"]
    /// What Go's `Executor.finish` appends to the error of a run whose
    /// script was abandoned before it disables the automation
    /// (`internal/automations/executor_run.go`); the reason follows it.
    nonisolated package static let disabledMarker = "; the automation was disabled: "
    nonisolated package static let noticeInterval: TimeInterval = 24 * 60 * 60

    nonisolated static let seenKey = "automations.failures.seenRunID"
    nonisolated static let handledKey = "automations.failures.handledRunID"
    nonisolated static let noticeKey = "automations.failures.lastNoticeAt"

    private let defaults: UserDefaults
    private let notifier: AutomationRunNotifying

    package init(defaults: UserDefaults, notifier: AutomationRunNotifying) {
        self.defaults = defaults
        self.notifier = notifier
    }

    /// The failed run this item's badge share is about, if any.
    nonisolated package static func failedRun(_ item: AutomationListItem) -> AutomationRun? {
        guard let run = item.lastRun, run.trigger != "dry_run", failedStatuses.contains(run.status) else { return nil }
        return run
    }

    /// The reason after `disabledMarker`, or nil when the run did not disable its automation.
    nonisolated package static func disabledReason(_ run: AutomationRun) -> String? {
        guard let range = run.error.range(of: disabledMarker) else { return nil }
        return String(run.error[range.upperBound...])
    }

    /// Automations whose newest ended run failed and was not seen.
    package func unseenCount(_ items: [AutomationListItem]) -> Int {
        let seen = numbers(Self.seenKey, \.int64Value)
        return items.filter { item in
            guard let run = Self.failedRun(item) else { return false }
            return run.id > (seen[key(item.id)] ?? 0)
        }.count
    }

    /// The owner looked at the card: its newest ended run is seen.
    package func markSeen(_ item: AutomationListItem) {
        guard let run = item.lastRun else { return }
        var seen = numbers(Self.seenKey, \.int64Value)
        guard run.id > (seen[key(item.id)] ?? 0) else { return }
        seen[key(item.id)] = run.id
        defaults.set(seen, forKey: Self.seenKey)
    }

    /// Posts the notices for failed runs not handled yet.
    package func notifyNewFailures(_ items: [AutomationListItem], now: Date) {
        var handled = numbers(Self.handledKey, \.int64Value)
        var notices = numbers(Self.noticeKey, \.doubleValue)
        let before = (handled, notices)
        for item in items {
            guard let run = Self.failedRun(item), run.id > (handled[key(item.id)] ?? 0) else { continue }
            let disabled = Self.disabledReason(run)
            guard disabled != nil || Self.backgroundTriggers.contains(run.trigger) else { continue }
            handled[key(item.id)] = run.id
            guard let finished = run.finishedAt, now.timeIntervalSince(finished) < Self.noticeInterval else { continue }
            let name = item.automation.name.isEmpty ? item.automation.slug : item.automation.name
            if let disabled {
                notifier.automationDisabled(name: name, reason: disabled, automationID: item.id, runID: run.id)
            } else {
                if let last = notices[key(item.id)],
                   now.timeIntervalSince(Date(timeIntervalSince1970: last)) < Self.noticeInterval { continue }
                notifier.runFinished(name: name, status: run.status, summary: run.summary, error: run.error,
                                     automationID: item.id, runID: run.id)
            }
            notices[key(item.id)] = now.timeIntervalSince1970
        }
        if handled != before.0 { defaults.set(handled, forKey: Self.handledKey) }
        if notices != before.1 { defaults.set(notices, forKey: Self.noticeKey) }
    }

    private func key(_ id: Int64) -> String { String(id) }

    private func numbers<T>(_ name: String, _ value: (NSNumber) -> T) -> [String: T] {
        (defaults.dictionary(forKey: name) as? [String: NSNumber])?.mapValues(value) ?? [:]
    }
}
