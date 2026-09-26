import Foundation
import GRDB

package struct MeetingRecap: Codable, FetchableRecord, PersistableRecord {
    package static let databaseTableName = "meeting_recaps"

    // Nullable since migration 00056: a recap outlives its event (event_id →
    // NULL on deletion, the durable link is transcript_id).
    package let eventID: String?
    package let sourceText: String
    package let recapJSON: String
    package let createdAt: String
    package let updatedAt: String

    package struct Content: Decodable, Equatable {
        package let summary: String
        package let keyDecisions: [String]
        package let actionItems: [String]
        package let openQuestions: [String]

        package init(summary: String, keyDecisions: [String], actionItems: [String], openQuestions: [String]) {
            self.summary = summary
            self.keyDecisions = keyDecisions
            self.actionItems = actionItems
            self.openQuestions = openQuestions
        }

        enum CodingKeys: String, CodingKey {
            case summary
            case keyDecisions = "key_decisions"
            case actionItems = "action_items"
            case openQuestions = "open_questions"
        }
    }

    package var parsed: Content? {
        guard let data = recapJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Content.self, from: data)
    }

    package enum CodingKeys: String, CodingKey {
        case eventID = "event_id"
        case sourceText = "source_text"
        case recapJSON = "recap_json"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}
