import Foundation
import GRDB

/// One `session_messages` row (00196): a message between two live sessions
/// of one workbench (PROJ-23). MCP inserts it, the daemon alone delivers it
/// and moves `state`; the Desktop only reads it — its one change, the
/// prompt-flag Dismiss, goes through `workbench message dismiss`.
/// `kind`, `state` and `reason` stay as stored: a value this build does not
/// know is shown as is, never read as another.
package struct SessionMessage: Codable, FetchableRecord, Identifiable, Hashable, Sendable {
    package let id: Int64
    package let workbenchID: Int64
    /// nil once the sending session was deleted.
    package let fromSessionID: Int64?
    /// nil once the receiving session was deleted.
    package let toSessionID: Int64?
    /// `message`, `finished` or `failure`.
    package let kind: String
    package let text: String
    package let createdAt: String
    /// `queued`, `delivering`, `delivered` or `failed`.
    package let state: String
    /// Why it ended as it did (`typed_not_submitted`, `not_running`, …); "" when none.
    package let reason: String
    package let deliveredAt: String?
    /// On a `typed_not_submitted` row: when its text left the receiver's
    /// prompt; nil while it may still sit there.
    package let promptClearedAt: String?

    package enum CodingKeys: String, CodingKey {
        case id, kind, text, state, reason
        case workbenchID = "workbench_id"
        case fromSessionID = "from_session_id"
        case toSessionID = "to_session_id"
        case createdAt = "created_at"
        case deliveredAt = "delivered_at"
        case promptClearedAt = "prompt_cleared_at"
    }

    /// The reason of a message typed into the receiver's prompt whose Return
    /// was withheld (Go `db.SessionMessageTypedNotSubmitted`).
    package static let typedNotSubmitted = "typed_not_submitted"
}
