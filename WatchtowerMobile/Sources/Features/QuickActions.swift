import Foundation
import SwiftUI
import WatchtowerKit

// MARK: - Snooze menu

/// The three snooze horizons offered by the swipe menus. Instants are computed
/// on the user's LOCAL calendar (wall-clock semantics — "tonight" means
/// tonight where the user is standing), then shipped through
/// `ActionOutbox.snoozeParams` as plain UTC ISO8601 — the wire form the
/// desktop parser accepts (pinned in Plan 2/3). Timezone correctness lives in
/// the Date computation here; the UTC rendering of that instant is exact.
enum SnoozeOption: String, CaseIterable, Identifiable {
    case oneHour
    case tonight
    case tomorrow

    var id: String { rawValue }

    var label: String {
        switch self {
        case .oneHour: return "1 hour"
        case .tonight: return "Tonight"
        case .tomorrow: return "Tomorrow"
        }
    }

    /// - `oneHour`: now + 1 h.
    /// - `tonight`: the NEXT 18:00 on the user's wall clock — today before
    ///   6 pm, tomorrow evening after; never an instant in the past.
    /// - `tomorrow`: the next local midnight (start of tomorrow), matching
    ///   the desktop's own "Till tomorrow" preset (InboxFeedView.snoozeItem).
    /// `now` and `calendar` are injectable so tests pin the math against a
    /// fixed instant in a fixed zone.
    func until(now: Date = Date(), calendar: Calendar = .current) -> Date {
        switch self {
        case .oneHour:
            return now.addingTimeInterval(3600)
        case .tonight:
            return calendar.nextDate(
                after: now,
                matching: DateComponents(hour: 18, minute: 0),
                matchingPolicy: .nextTime
            ) ?? now.addingTimeInterval(3600)
        case .tomorrow:
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
            return calendar.startOfDay(for: tomorrow)
        }
    }
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
