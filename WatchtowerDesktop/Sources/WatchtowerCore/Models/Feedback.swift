import GRDB
import Foundation

package struct Feedback: FetchableRecord, Decodable, Identifiable, Equatable {
    package let id: Int
    package let entityType: String  // "digest", "track", "decision"
    package let entityID: String
    package let rating: Int         // +1 = good, -1 = bad
    package let comment: String
    package let createdAt: String

    package enum CodingKeys: String, CodingKey {
        case id, rating, comment
        case entityType = "entity_type"
        case entityID = "entity_id"
        case createdAt = "created_at"
    }

    package var isPositive: Bool { rating > 0 }
}

package struct FeedbackStats: Equatable {
    package let entityType: String
    package let positive: Int
    package let negative: Int
    package let total: Int

    package init(entityType: String, positive: Int, negative: Int, total: Int) {
        self.entityType = entityType
        self.positive = positive
        self.negative = negative
        self.total = total
    }

    package var positivePercent: Int {
        total > 0 ? positive * 100 / total : 0
    }
}
