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
package struct InboxRowActionsContent: Equatable, Sendable {
    package enum Kind: Equatable, Sendable {
        /// A ping: Open (with a permalink, under its source's label),
        /// Reply… (Slack, Jira, Linear), Done, Hide, Snooze ▾, ⋯ (Discuss in
        /// Chat, Hand to Agent…).
        case inboxItem(openLabel: String?, canReply: Bool)
        /// A track: Done, ⋯ (Stop watching, Make a Task — or, for a custom
        /// track, Go to Target and Delete…).
        case track(custom: Bool)
        /// An idea: the verdict buttons while it awaits one (Approve,
        /// Reject, Not now ▾), else Activate and Drop.
        case idea(awaitsVerdict: Bool)
        /// A due reminder: Done, Snooze 1h.
        case reminder
        /// A proposal: Approve, Reject, Edit…; after a failed apply Retry
        /// and Dismiss.
        case action(failed: Bool)
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
}
