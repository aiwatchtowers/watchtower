import Foundation
import SwiftUI
import WatchtowerKit

// MARK: - Snooze menu

/// The snooze horizons offered by the swipe menus (see `inboxCases` /
/// `targetCases` for which tab offers which). Instants are computed on the
/// user's LOCAL calendar (wall-clock semantics — "tonight" means tonight
/// where the user is standing), then shipped through
/// `ActionOutbox.snoozeParams` as plain UTC ISO8601 — the wire form the
/// desktop parser accepts (pinned in Plan 2/3). Timezone correctness lives in
/// the Date computation here; the UTC rendering of that instant is exact.
enum SnoozeOption: String, CaseIterable, Identifiable {
    case oneHour
    case tonight
    case tomorrow
    case nextWeek

    var id: String { rawValue }

    var label: String {
        switch self {
        case .oneHour: return "1 hour"
        case .tonight: return "Tonight"
        case .tomorrow: return "Tomorrow"
        case .nextWeek: return "Next week"
        }
    }

    /// - `oneHour`: now + 1 h.
    /// - `tonight`: the NEXT 18:00 on the user's wall clock — today before
    ///   6 pm, tomorrow evening after; never an instant in the past.
    /// - `tomorrow`: the next local midnight (start of tomorrow), matching
    ///   the desktop's own "Till tomorrow" preset (InboxFeedView.snoozeItem).
    /// - `nextWeek`: local midnight of `now + 7 days` — same day-granularity
    ///   discipline as `tomorrow` (see `targetCases`).
    /// `now` and `calendar` are injectable so tests pin the math against a
    /// fixed instant in a fixed zone.
    func until(now: Date = Date(), calendar: Calendar = .current) -> Date {
        switch self {
        case .oneHour:
            return now.addingTimeInterval(3600)
        case .tonight:
            if let next = calendar.nextDate(
                after: now,
                matching: DateComponents(hour: 18, minute: 0),
                matchingPolicy: .nextTime
            ) {
                return next
            }
            assertionFailure("SnoozeOption.tonight: calendar could not compute the next 18:00")
            return now.addingTimeInterval(3600)
        case .tomorrow:
            guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) else {
                assertionFailure("SnoozeOption.tomorrow: calendar could not add 1 day to \(now)")
                return calendar.startOfDay(for: now)
            }
            return calendar.startOfDay(for: tomorrow)
        case .nextWeek:
            guard let nextWeek = calendar.date(byAdding: .day, value: 7, to: now) else {
                assertionFailure("SnoozeOption.nextWeek: calendar could not add 7 days to \(now)")
                return calendar.startOfDay(for: now)
            }
            return calendar.startOfDay(for: nextWeek)
        }
    }

    /// Snooze menu offered on the Inbox tab: full horizon range, hour-level
    /// granularity included (implicit/ambient items tolerate the desktop's
    /// own `snooze_until` handling at that resolution).
    static let inboxCases: [SnoozeOption] = [.oneHour, .tonight, .tomorrow]

    /// Snooze menu offered on the Tasks (targets) tab: DAY granularity only.
    /// `TargetQueries.snooze` (desktop) stores a bare Mac-local `yyyy-MM-dd`
    /// with no time-of-day, and Go's `UnsnoozeExpiredTargets`
    /// (internal/db/targets.go) compares `snooze_until <= "YYYY-MM-DDTHH:mm"`
    /// lexicographically — a same-day bare date sorts before any timestamp
    /// later that same day, so it unsnoozes IMMEDIATELY. Offering `.oneHour`
    /// or `.tonight` here would be a silent no-op: the menu would look like it
    /// worked, but the target reappears at the next unsnooze sweep. Match the
    /// desktop's own target UI, which only offers day-level presets.
    static let targetCases: [SnoozeOption] = [.tomorrow, .nextWeek]
}

// MARK: - Pending overlay join

/// Pure join logic between `pending_actions` overlay rows and the slice
/// models (Plan 4 decision 4: optimistic state is an overlay — `slice_records`
/// is never mutated locally). Shared by the Inbox and Tasks view models.
enum PendingOverlay {
    /// The still-pending action to render as a chip on the row named
    /// `recordName`, or nil. Suppressed when the row's `status` ALREADY shows
    /// the action's outcome: hydration can land before the desktop's echo
    /// clears the overlay, and a "pending" chip on an already-done row would
    /// read as a lie (Task 3 review, ordering walk case 2).
    static func chip(
        forRecordName recordName: String,
        status: String,
        in pending: [PendingAction]
    ) -> PendingAction? {
        pending.first { row in
            row.state == .pending
                && row.entityRecordName == recordName
                && outcomeStatus(of: row.action.kind) != status
        }
    }

    /// Failed overlay rows for one tab's banner area; `kinds` scopes the tab
    /// (inbox kinds vs target kinds) so a failure surfaces exactly once.
    static func failed(in pending: [PendingAction], kinds: Set<ActionKind>) -> [PendingAction] {
        pending.filter { $0.state == .failed && kinds.contains($0.action.kind) }
    }

    /// Re-enqueues a failed action verbatim (same kind/entity/params, fresh
    /// id), then drops the failed row. Enqueue FIRST: a transport throw keeps
    /// the old banner up for another try instead of losing the action.
    static func retry(_ failed: PendingAction, outbox: ActionOutbox, store: ReplicaStore) async throws {
        _ = try await outbox.enqueue(
            kind: failed.action.kind,
            entityRecordName: failed.entityRecordName,
            params: failed.action.params
        )
        try store.removePendingAction(id: failed.id)
    }

    /// The slice `status` value an action produces once the desktop applies
    /// it — the suppress-the-chip comparison key. Nil = the action has no
    /// status-shaped outcome, so its chip is never suppressed.
    static func outcomeStatus(of kind: ActionKind) -> String? {
        switch kind {
        case .targetDone: return "done"
        case .targetSnooze, .inboxSnooze: return "snoozed"
        case .inboxResolve: return "resolved"
        case .inboxDismiss: return "dismissed"
        case .taskCreate, .trackRead: return nil
        }
    }

    /// Short human label for an action kind (failed-action banner copy).
    static func label(of kind: ActionKind) -> String {
        switch kind {
        case .targetDone: return "Mark done"
        case .targetSnooze, .inboxSnooze: return "Snooze"
        case .inboxResolve: return "Resolve"
        case .inboxDismiss: return "Dismiss"
        case .taskCreate: return "Create task"
        case .trackRead: return "Mark read"
        }
    }

    /// The typed text of a failed `task_create` action, or nil for any other
    /// kind. `task_create` is entity-less (no slice row to show), so without
    /// this the failed-action banner is just "Create task failed" with no way
    /// to see WHICH text failed — Dismiss would then discard it invisibly.
    static func taskCreateText(of failed: PendingAction) -> String? {
        guard failed.action.kind == .taskCreate else { return nil }
        guard case .string(let text) = failed.action.params["text"] else { return nil }
        return text
    }
}

// MARK: - Failed-action banner

/// One failed action surfaced at the top of a tab's list: the desktop's (or
/// the silent-pending sweep's) message plus Retry / Dismiss. The host row has
/// already restored its normal appearance — failed rows never dim anything.
struct FailedActionBanner: View {
    let failed: PendingAction
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                "\(PendingOverlay.label(of: failed.action.kind)) failed",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(.red)
            Text(failed.errorMessage ?? "Unknown error")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let text = PendingOverlay.taskCreateText(of: failed) {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
            HStack(spacing: 16) {
                Button("Retry", action: onRetry)
                Button("Dismiss", role: .cancel, action: onDismiss)
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }
}
