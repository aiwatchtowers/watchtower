import Foundation
import GRDB

package struct InboxFeedback: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    package static let databaseTableName = "inbox_feedback"

    package var id: Int64?
    package var inboxItemId: Int64
    package var rating: Int
    package var reason: String
    package var createdAt: String

    package init(id: Int64? = nil, inboxItemId: Int64, rating: Int, reason: String, createdAt: String) {
        self.id = id
        self.inboxItemId = inboxItemId
        self.rating = rating
        self.reason = reason
        self.createdAt = createdAt
    }

    package enum CodingKeys: String, CodingKey {
        case id
        case inboxItemId = "inbox_item_id"
        case rating
        case reason
        case createdAt = "created_at"
    }
}
