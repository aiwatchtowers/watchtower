import Foundation
import GRDB

/// One `reminders` row — a reaction-command-created follow-up. Rows are
/// created by the `remind_me` agent-actions tool (Go, `internal/tools/remind.go`);
/// Done/Snooze are Swift-owned direct GRDB writes (`ReminderQueries.markDone`/
/// `snooze`, a dual-path — the `inbox_feedback` precedent). Mirrors `internal/db/reminders.go`.
package struct Reminder: FetchableRecord, Identifiable, Equatable, Sendable {
    package let id: Int64
    package let accountID: Int64
    package let messageRef: String
    package let note: String
    package let remindAt: String
    package let status: String
    package let createdAt: String
    package let doneAt: String

    package init(row: Row) {
        id = row["id"]
        accountID = row["account_id"] ?? 0
        messageRef = row["message_ref"] ?? ""
        note = row["note"] ?? ""
        remindAt = row["remind_at"] ?? ""
        status = row["status"] ?? "pending"
        createdAt = row["created_at"] ?? ""
        doneAt = row["done_at"] ?? ""
    }
}
