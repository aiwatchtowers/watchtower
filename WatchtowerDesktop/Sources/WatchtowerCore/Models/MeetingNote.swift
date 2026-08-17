import Foundation
import GRDB

package struct MeetingNote: Codable, FetchableRecord, PersistableRecord, Identifiable {
    package static let databaseTableName = "meeting_notes"

    package var id: Int64?
    package var eventID: String
    package var type: NoteType
    package var text: String
    package var isChecked: Bool
    package var sortOrder: Int
    package var taskID: Int64?
    package var createdAt: String
    package var updatedAt: String

    package init(
        id: Int64? = nil,
        eventID: String,
        type: NoteType,
        text: String,
        isChecked: Bool,
        sortOrder: Int,
        taskID: Int64? = nil,
        createdAt: String,
        updatedAt: String
    ) {
        self.id = id
        self.eventID = eventID
        self.type = type
        self.text = text
        self.isChecked = isChecked
        self.sortOrder = sortOrder
        self.taskID = taskID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    package enum NoteType: String, Codable {
        case question
        case note
    }

    package enum CodingKeys: String, CodingKey {
        case id, text, type
        case eventID = "event_id"
        case isChecked = "is_checked"
        case sortOrder = "sort_order"
        case taskID = "task_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    package mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
