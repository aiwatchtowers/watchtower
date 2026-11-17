import Foundation
import WatchtowerInterface

/// One Inbox target button as the Mac draws it (spec "The Desktop button"):
/// Go's state for it — the feed's `CardAction.detail`, `note` and `until`,
/// or an approval card's `target`, `target_note` and `target_until` — and
/// this Desktop's own processes on it, which only the Mac knows. The app's
/// `TargetButtonStateResolver` maps it onto DesignKit's
/// `ArtifactTargetButtonState`, which WatchtowerCore cannot see.
package struct InboxTargetButton: Equatable, Sendable {
    /// Go's state: idle, waiting, creating, stuck, failed or created ("" and
    /// any other value read as idle).
    package var detail: String
    /// A failed button's message; "" otherwise.
    package var note: String
    /// When a creating button reads as stuck (Go's `until`); nil otherwise.
    package var until: Date?
    /// The button's newest proposal row: where a waiting button's click
    /// opens and what Try again applies again; nil when there is none.
    package var proposalID: Int64?
    /// The task that row made, which a created button opens; nil when none.
    package var taskID: Int64?
    /// This Desktop's own approve or apply process for the row is running.
    package var inFlight: Bool
    /// Why this button's last propose failed; kept by the Inbox center until
    /// a propose succeeds or a newer row shows.
    package var pressError: String?
    /// Why this Desktop's last Approve, apply or Try again of the row failed
    /// without moving it (`AgentActionFeed.rowErrors`).
    package var applyError: String?

    package init(
        detail: String = "",
        note: String = "",
        until: Date? = nil,
        proposalID: Int64? = nil,
        taskID: Int64? = nil,
        inFlight: Bool = false,
        pressError: String? = nil,
        applyError: String? = nil
    ) {
        self.detail = detail
        self.note = note
        self.until = until
        self.proposalID = proposalID
        self.taskID = taskID
        self.inFlight = inFlight
        self.pressError = pressError
        self.applyError = applyError
    }

    /// Go's state of a card's target action; idle when the feed has none.
    package init(action: CardAction?) {
        self.init(detail: action?.detail ?? "", note: action?.note ?? "", until: Self.date(action?.until ?? ""))
    }

    /// Go's state of the button an approval card's proposal belongs to; nil
    /// when the proposal is not a target button's newest row.
    package init?(approval: Approval?) {
        guard let approval, !approval.target.isEmpty else { return nil }
        self.init(detail: approval.target, note: approval.targetNote, until: Self.date(approval.targetUntil))
    }

    /// An RFC 3339 UTC time from Go, with or without fractional seconds;
    /// nil when empty or unreadable.
    package static func date(_ text: String) -> Date? {
        guard !text.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
}
