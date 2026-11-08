import Foundation

/// What the Desktop knows about one Inbox target button (spec "The Desktop
/// button"): facts only. The app's `TargetButtonStateResolver` maps them
/// onto DesignKit's `ArtifactTargetButtonState`, which WatchtowerCore
/// cannot see.
package struct InboxTargetButtonFacts: Equatable, Sendable {
    /// The newest `agent_actions` row of the button's context; nil = none.
    package var proposal: Proposal?
    /// The applied row's task (`targets.source_id = 'action:<id>'`); nil
    /// when there is none or it was deleted.
    package var taskID: Int64?
    package var taskExists: Bool { taskID != nil }
    /// This Desktop's own approve or apply process for the row is running.
    package var inFlight: Bool
    /// Why this button's last propose failed (a non-zero exit other than 3);
    /// kept by the Inbox center until a propose succeeds or a newer row shows.
    package var pressError: String?
    /// Why this Desktop's last Approve, apply or Try again of the row failed
    /// without moving it (`AgentActionFeed.rowErrors`).
    package var applyError: String?

    package init(
        proposal: Proposal? = nil,
        taskID: Int64? = nil,
        inFlight: Bool = false,
        pressError: String? = nil,
        applyError: String? = nil
    ) {
        self.proposal = proposal
        self.taskID = taskID
        self.inFlight = inFlight
        self.pressError = pressError
        self.applyError = applyError
    }

    /// The proposal row's columns the button reads.
    package struct Proposal: Equatable, Sendable {
        package let id: Int64
        package let status: String
        package let decidedAt: String
        package let dismissedAt: String
        package let error: String
        package let resultJSON: String

        package init(_ row: AgentAction) {
            id = row.id
            status = row.status
            decidedAt = row.decidedAt
            dismissedAt = row.dismissedAt
            error = row.error
            resultJSON = row.resultJSON
        }

        /// `decided_at` (Go RFC 3339 UTC); nil when empty or unreadable.
        package var decidedDate: Date? {
            let formatter = ISO8601DateFormatter()
            if let date = formatter.date(from: decidedAt) { return date }
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: decidedAt)
        }
    }
}
