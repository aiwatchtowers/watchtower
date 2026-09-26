import Foundation
import GRDB

package struct ChatConversation: FetchableRecord, Decodable, Identifiable, Equatable {
    package let id: Int64
    package let title: String
    package let sessionID: String?
    package let contextType: String?
    package let contextID: String?
    package let createdAt: Double
    package let updatedAt: Double

    package enum CodingKeys: String, CodingKey {
        case id
        case title
        case sessionID = "session_id"
        case contextType = "context_type"
        case contextID = "context_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    package var createdDate: Date {
        Date(timeIntervalSince1970: createdAt)
    }

    package var updatedDate: Date {
        Date(timeIntervalSince1970: updatedAt)
    }

    package var displayTitle: String {
        title.isEmpty ? "New Chat" : title
    }
}
