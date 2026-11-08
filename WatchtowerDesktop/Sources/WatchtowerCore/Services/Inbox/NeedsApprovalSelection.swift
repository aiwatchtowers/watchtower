import Foundation

/// The `needs-approval` built-in as Needs approval's composition needs it
/// (spec "Needs approval" → What the Desktop shows), read with the folder.
package struct NeedsApprovalState: Equatable, Sendable {
    /// The built-in's automation row; nil before it is indexed.
    package let automationID: Int64?
    /// The daemon stopped it after a run that would not end (AUTO-08): its
    /// row's `disabled_reason` is set.
    package let stopped: Bool
    /// Its latest finished run failed.
    package let lastRunFailed: Bool
    /// The latest failed run, for **Run History**; nil when none is left.
    package let latestFailedRunID: Int64?

    package init(
        automationID: Int64?,
        stopped: Bool = false,
        lastRunFailed: Bool = false,
        latestFailedRunID: Int64? = nil
    ) {
        self.automationID = automationID
        self.stopped = stopped
        self.lastRunFailed = lastRunFailed
        self.latestFailedRunID = latestFailedRunID
    }

    /// Not indexed yet (or an older database): nothing to draw from.
    package static let absent = Self(automationID: nil)

    /// The note Needs approval shows above its cards, or nil when it shows
    /// none: off (the `approval-cards` feature), stopped, last run failed —
    /// in that order.
    package func noteState(featureOn: Bool) -> NeedsApprovalNoteContent.State? {
        if !featureOn { return .off }
        if stopped { return .stopped }
        if lastRunFailed { return .lastRunFailed }
        return nil
    }
}

/// One open approval (spec "What 'open' means": an `action` awaiting the
/// owner, or a due `reminder`) as Needs approval draws it: the recipe's
/// card when it is current, else today's native card.
package struct NeedsApprovalItem: Identifiable, Equatable, Sendable {
    package enum Record: Equatable, Sendable {
        case action(AgentAction)
        case reminder(Reminder)
    }

    package let record: Record
    /// The recipe's artifact for it; nil draws the native card.
    package let recipe: AutomationOutputCard?

    package init(_ record: Record, recipe: AutomationOutputCard? = nil) {
        self.record = record
        self.recipe = recipe
    }

    /// `action:<id>` / `reminder:<id>`: the built-in's artifact key (ask #964).
    package var key: String { "\(ref.kind.rawValue):\(ref.id)" }
    package var id: String { key }

    package var ref: InboxRef {
        switch record {
        case let .action(action): InboxRef(kind: .action, id: action.id)
        case let .reminder(reminder): InboxRef(kind: .reminder, id: reminder.id)
        }
    }

    /// Its last change, as Go's `OpenApproval.ChangedAt` reads it: the
    /// latest of an action's created, decided and applied times, or of a
    /// reminder's created and due times. An unreadable time counts as never.
    package var changedAt: Date {
        let stamps: [String] = switch record {
        case let .action(action): [action.createdAt, action.decidedAt, action.appliedAt]
        case let .reminder(reminder): [reminder.createdAt, reminder.remindAt]
        }
        return stamps.compactMap(AutomationDates.parse).max() ?? .distantPast
    }

    /// Its own time in the list: created (an action) or due (a reminder).
    package var listedAt: Date {
        switch record {
        case let .action(action): AutomationDates.parse(action.createdAt) ?? .distantPast
        case let .reminder(reminder): AutomationDates.parse(reminder.remindAt) ?? .distantPast
        }
    }
}

/// Recipe card or native card, per open approval (spec "What the Desktop
/// shows"; APPROVAL-01): an approval never waits on a run, a failed run
/// never hides one, and a closed one is never drawn.
package enum NeedsApprovalSelection {
    package enum Pick: Equatable, Sendable { case recipe, native }

    /// The recipe's card only when all four hold: the recipe is on, its
    /// latest run did not fail, its artifact for this approval exists, and
    /// that artifact was written at or after the approval's last change.
    package static func pick(
        approval: NeedsApprovalItem,
        artifact: AutomationOutputCard?,
        recipeOn: Bool,
        lastRunFailed: Bool
    ) -> Pick {
        guard recipeOn, !lastRunFailed, let artifact, artifact.writtenAt >= approval.changedAt else { return .native }
        return .recipe
    }

    /// Every open approval — `proposals` and `reminders` as the Inbox's one
    /// read found them open — with its card picked. `artifacts` are the
    /// built-in's own cards, by key; one whose approval is not open here is
    /// never drawn, whatever the run did. Oldest first, as the recipe writes
    /// them (actions before reminders on a tie).
    package static func items(
        proposals: [AgentAction],
        reminders: [Reminder],
        artifacts: [String: AutomationOutputCard],
        recipeOn: Bool,
        lastRunFailed: Bool
    ) -> [NeedsApprovalItem] {
        let open = proposals.map { NeedsApprovalItem(.action($0)) } + reminders.map { NeedsApprovalItem(.reminder($0)) }
        return open.map { item in
            let artifact = artifacts[item.key]
            let picked = pick(approval: item, artifact: artifact, recipeOn: recipeOn, lastRunFailed: lastRunFailed)
            return NeedsApprovalItem(item.record, recipe: picked == .recipe ? artifact : nil)
        }
    }
}
