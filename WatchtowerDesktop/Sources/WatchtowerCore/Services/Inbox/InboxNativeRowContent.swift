import Foundation

/// Why Needs approval shows today's native cards instead of the recipe's,
/// and what its one press does (spec "Needs approval" → States).
package struct NeedsApprovalNoteContent: Equatable, Sendable {
    package enum State: Equatable, Sendable {
        /// The `approval-cards` feature is off: **Turn On** enables it.
        case off
        /// The built-in was stopped under AUTO-08 while the feature is on:
        /// its own **Turn On** resumes it (`resumeStoppedBuiltin`).
        case stopped
        /// The latest `needs-approval` run failed: **Run History**.
        case lastRunFailed
    }

    package let state: State
    /// The reason the last Turn On returned; the note stays.
    package var failure: String?
    /// A Turn On under way.
    package var isApplying: Bool

    package init(state: State, failure: String? = nil, isApplying: Bool = false) {
        self.state = state
        self.failure = failure
        self.isApplying = isApplying
    }

    package var text: String {
        switch state {
        case .off: "Showing approvals in the standard card — Needs approval is off."
        case .stopped:
            "Showing approvals in the standard card — Needs approval was stopped after a run that would not end."
        case .lastRunFailed: "Showing approvals in the standard card — the last run failed."
        }
    }

    package var buttonTitle: String {
        state == .lastRunFailed ? "Run History" : "Turn On"
    }
}

/// The native actions of one artifact row with a `ref` (spec "Native row
/// actions for a `ref`"): exactly that kind's Inbox card buttons today, plus
/// **Reply…** on an `inbox_item` with a write path (asks #445, #451).
package struct InboxRowActionsContent: Equatable {
    package enum Kind: Equatable {
        /// A ping (`InboxMessagePane`): Open under its source's label while
        /// it has a permalink, disabled when `InboxCardLinkPolicy` refuses
        /// it; Reply… (Slack, Jira, Linear); Done, Hide, Snooze ▾; ⋯ with
        /// Discuss in Chat and, when the card offers it, Hand to Agent….
        case inboxItem(openLabel: String?, openEnabled: Bool, canReply: Bool, showsHandToAgent: Bool)
        /// A track (`InboxTrackPane`): Done, ⋯ Stop watching and Make a Task
        /// (extracted) or Delete… (custom), Go to Target only with a linked
        /// target.
        case track(custom: Bool, linkedTargetID: Int64?)
        /// An idea: `IdeaDetailPane`'s verdict buttons for its kind and
        /// status (`ideaButtons`).
        case idea(kind: Idea.Kind, status: Idea.Status, awaitsVerdict: Bool)
        /// A due reminder: Done, Snooze 1h.
        case reminder
        /// A proposal: the buttons its native card offers today
        /// (`AgentActionCardView.rowButtons`).
        case action(buttons: [ActionButton])
    }

    /// One of a proposal row's buttons. **Edit…** and **Open Draft** open
    /// the native card (its argument editor, the automation editor) where
    /// the row cannot make a press the way the card does.
    package enum ActionButton: Equatable, Sendable {
        case approve, reject, edit, openDraft, retry, dismiss
    }

    package enum State: Equatable, Sendable {
        case idle
        /// A press on this row runs: its buttons wait, a progress mark shows.
        case busy
        /// The last press failed: the row stays with the error and **Retry**.
        case failed(message: String)
    }

    /// The Reply composer under an `inbox_item` row, or the caption while
    /// its proposal waits in Needs approval.
    package enum Reply: Equatable, Sendable {
        case composing(text: String, error: String?)
        case waiting
    }

    /// One of an idea row's buttons.
    package enum IdeaButton: Equatable, Sendable {
        case approve, makeTask, notNow, reject, activate, drop
    }

    package let kind: Kind
    package var state: State
    package var reply: Reply?
    /// A's `.preview` mode: every native action drawn disabled.
    package var isPreview: Bool

    package init(kind: Kind, state: State = .idle, reply: Reply? = nil, isPreview: Bool = false) {
        self.kind = kind
        self.state = state
        self.reply = reply
        self.isPreview = isPreview
    }

    package var isBusy: Bool { state == .busy }

    /// `IdeaActionBar`'s verdict buttons, without its Merge, delete and a
    /// decision's Supersede / Reverse (the full pane opens on a press of
    /// the row): awaiting a verdict → Approve, Make a Task (ideas), Not now
    /// (not notes), Reject; an active idea → Make a Task, Not now, Drop; a
    /// not-now idea → Activate, Make a Task, Drop; an active note → Drop; a
    /// rejected or dropped one (and a decision not now) → Activate.
    package static func ideaButtons(kind: Idea.Kind, status: Idea.Status, awaitsVerdict: Bool) -> [IdeaButton] {
        if awaitsVerdict {
            return [.approve] + (kind == .idea ? [.makeTask] : []) + (kind == .note ? [] : [.notNow]) + [.reject]
        }
        if kind == .decision {
            return [.rejected, .dropped, .notNow].contains(status) ? [.activate] : []
        }
        switch (kind, status) {
        case (.idea, .active): return [.makeTask, .notNow, .drop]
        case (.idea, .notNow): return [.activate, .makeTask, .drop]
        case (.note, .active): return [.drop]
        case (_, .rejected), (_, .dropped): return [.activate]
        default: return []
        }
    }
}

/// A press on a row's native actions (`InboxRowActionsView`).
package enum InboxRowPress: Equatable, Sendable {
    case open, reply, done, hide, snooze(duration: String), discussInChat, handToAgent
    case stopWatching, makeTask, goToTarget, deleteTrack
    case approve, reject, edit, openDraft, retry, dismiss, notNow(until: String), activate, drop
    case snoozeHour
    /// **Retry** under a failed press: repeats it.
    case retryFailedPress
    case replyChanged(String), proposeReply, cancelReply
}

/// A row's failed press (spec "Native row actions", Failure): the message
/// shown under the row and the press its **Retry** repeats.
package struct InboxRowFailure: Equatable, Sendable {
    package let message: String
    package let press: InboxRowPress

    package init(message: String, press: InboxRowPress) {
        self.message = message
        self.press = press
    }
}

package extension InboxRef {
    /// The strip's key for this ref's record: its busy flag and row error.
    var selection: InboxSelection {
        switch kind {
        case .inboxItem: .message(Int(id))
        case .track: .track(Int(id))
        case .idea: .idea(Int(id))
        case .reminder: .reminder(id)
        case .action: .proposal(id)
        }
    }
}
